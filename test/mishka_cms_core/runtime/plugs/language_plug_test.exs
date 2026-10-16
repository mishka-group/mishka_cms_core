# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Plugs.LanguagePlugTest do
  @moduledoc """
  Every request is answered in the language its address names, in either URL mode, and no request
  that is not the CMS's to answer is moved or remembered.

  The rule is asked of the routing table rather than of a list of exceptions, so what it leaves
  alone — a page stored without a language, a route Phoenix owns — is decided by the same lookup the
  request itself is about to make. `call/2` is driven through `PagesRouter` below, the CMS's shape:
  one route of Phoenix's own, and a catch-all the CMS answers.
  """
  use MishkaCmsCore.DataCase, async: false

  defmodule PagesRouter do
    @moduledoc false
    use Phoenix.Router
    import Phoenix.LiveView.Router

    live "/admin/dashboard", MishkaCmsCore.Test.KitUpgradeHostLive
    live "/*path", MishkaCmsCore.Test.ActivityFeedHostLive
  end

  import Plug.Conn
  import Plug.Test

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Plugs.LanguagePlug
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  @moduletag :integration

  @router PagesRouter
  @cms MishkaCmsCore.Test.ActivityFeedHostLive

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "lang-plug-#{n}", host: "lang-plug-#{n}.test")

    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

    forget_settings(~w(site.languages site.language_urls), [site.id])
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    on_exit(fn ->
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.delete(site.id)
    end)

    %{site: site, where: {site.name, site.id}}
  end

  defp route!(site, path, language \\ nil) do
    :ok =
      WebRunTimeMetaDataState.save(%{
        id: "#{path}-#{System.unique_integer([:positive])}",
        site: site.name,
        path: path,
        title: path,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: 0,
        language: language
      })
  end

  defp request(site, path, session \\ %{}) do
    :get
    |> conn(path)
    |> assign(:current_site, %{name: site.name, id: site.id})
    |> init_test_session(session)
  end

  defp opts, do: LanguagePlug.init(router: @router, live_view: @cms)

  defp prefix_all!(site),
    do: {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

  # THE DEFAULT: the primary language has no prefix, and the address alone decides.
  describe "target/3 — a site that leaves its primary language unprefixed" do
    test "a first segment that is another of the site's languages is the answer", %{
      where: where
    } do
      assert LanguagePlug.target(["fa", "pricing"], where, nil) == {:serve, "fa"}
      assert LanguagePlug.target(["fa"], where, "en") == {:serve, "fa"}
    end

    test "the primary language's prefix is sent away for good", %{where: where} do
      assert LanguagePlug.target(["en", "blog"], where, nil) == {:redirect, "/blog", 301}

      assert LanguagePlug.target(["en", "blog", "post"], where, "fa") ==
               {:redirect, "/blog/post", 301}

      assert LanguagePlug.target(["en"], where, nil) == {:redirect, "/", 301}
    end

    # The owner's decision: the address decides, so `/` is the primary language's home for a
    # browser in Persian and a session in Persian alike.
    test "an address that names no language is the primary one, whatever is remembered", %{
      site: site,
      where: where
    } do
      route!(site, "/:lang/blog")
      route!(site, "/:lang")

      assert LanguagePlug.target(["blog"], where, "fa") == {:serve, "en"}
      assert LanguagePlug.target([], where, "fa") == {:serve, "en"}
      assert LanguagePlug.target(["nothing", "here"], where, nil) == {:serve, "en"}
    end

    test "a segment that only looks like a language is not one", %{site: site, where: where} do
      route!(site, "/de/about")

      assert LanguagePlug.target(["de", "about"], where, nil) == {:serve, "en"}
    end

    test "the site's order decides which language goes unprefixed", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)
      where = {site.name, site.id}

      assert LanguagePlug.target(["fa", "blog"], where, nil) == {:redirect, "/blog", 301}
      assert LanguagePlug.target(["en", "blog"], where, nil) == {:serve, "en"}
      assert LanguagePlug.target(["blog"], where, "en") == {:serve, "fa"}
    end
  end

  describe "target/3 — a site that prefixes every language" do
    setup %{site: site} do
      prefix_all!(site)
      :ok
    end

    test "an address that names a language is answered in it", %{where: where} do
      assert LanguagePlug.target(["fa", "pricing"], where, nil) == {:serve, "fa"}
      assert LanguagePlug.target(["en"], where, "fa") == {:serve, "en"}
    end

    test "a page stored without a language keeps its address, in its own language", %{
      site: site,
      where: where
    } do
      route!(site, "/no-lang", "fa")
      route!(site, "/plain")

      assert LanguagePlug.target(["no-lang"], where, nil) == {:serve, "fa"}
      assert LanguagePlug.target(["plain"], where, "fa") == {:serve, "en"}
    end

    test "a page that resolves only under a language is sent there for now", %{
      site: site,
      where: where
    } do
      route!(site, "/:lang/blog")
      route!(site, "/:lang")

      assert LanguagePlug.target(["blog"], where, nil) == {:redirect, "/en/blog", 302}
      assert LanguagePlug.target([], where, nil) == {:redirect, "/en", 302}
    end

    test "a remembered language is where a visitor is sent", %{site: site, where: where} do
      route!(site, "/:lang/blog")

      assert LanguagePlug.target(["blog"], where, "fa") == {:redirect, "/fa/blog", 302}
    end

    # A visitor who once chose Persian asking for an address that names no language is not asking
    # for Persian — and sending them to a Persian page nobody wrote is a 404 a visitor with no
    # session at all does not get.
    test "a remembered language the page has no edition in falls back to the site's first",
         %{site: site, where: where} do
      route!(site, "/:lang/blog", "en")

      assert LanguagePlug.target(["blog"], where, "fa") == {:redirect, "/en/blog", 302}
    end

    test "but an address that names a language is never moved off it", %{site: site, where: where} do
      route!(site, "/:lang/blog", "en")

      assert LanguagePlug.target(["fa", "blog"], where, nil) == {:serve, "fa"}
    end

    test "an address that resolves under neither form is left alone", %{where: where} do
      assert LanguagePlug.target(["nothing", "here"], where, nil) == {:serve, "en"}
    end

    test "the site's order decides, so the first language is the default", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)
      route!(site, "/:lang/blog")

      assert LanguagePlug.target(["blog"], {site.name, site.id}, nil) ==
               {:redirect, "/fa/blog", 302}
    end
  end

  describe "call/2" do
    test "redirects and keeps the query string", %{site: site} do
      prefix_all!(site)
      route!(site, "/:lang/blog")

      conn = request(site, "/blog?page=2&q=ash") |> LanguagePlug.call(opts())

      assert conn.status == 302
      assert conn.halted
      assert get_resp_header(conn, "location") == ["/en/blog?page=2&q=ash"]
    end

    test "sends the primary language's prefix away for good, query kept", %{site: site} do
      route!(site, "/:lang/blog")

      conn = request(site, "/en/blog?page=2") |> LanguagePlug.call(opts())

      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["/blog?page=2"]
    end

    test "remembers the language a visitor is reading in", %{site: site} do
      route!(site, "/:lang/pricing")

      conn = request(site, "/fa/pricing") |> LanguagePlug.call(opts())

      refute conn.halted
      assert get_session(conn, Languages.session()) == "fa"
      assert conn.assigns.site_language == "fa"
    end

    test "the remembered language decides the next unprefixed address", %{site: site} do
      prefix_all!(site)
      route!(site, "/:lang/blog")

      conn =
        site
        |> request("/blog", %{Languages.session() => "fa"})
        |> LanguagePlug.call(opts())

      assert get_resp_header(conn, "location") == ["/fa/blog"]
    end

    test "but not while the primary language is unprefixed", %{site: site} do
      route!(site, "/:lang/blog")

      conn =
        site
        |> request("/blog", %{Languages.session() => "fa"})
        |> LanguagePlug.call(opts())

      refute conn.halted
      assert conn.status == nil
      assert conn.assigns.site_language == "en"
      assert get_session(conn, Languages.session()) == "en"
    end

    test "a remembered language the site no longer publishes in is ignored", %{site: site} do
      prefix_all!(site)
      route!(site, "/:lang/blog")

      conn =
        site
        |> request("/blog", %{Languages.session() => "de"})
        |> LanguagePlug.call(opts())

      assert get_resp_header(conn, "location") == ["/en/blog"]
    end

    test "Gettext answers in the language of the response", %{site: site} do
      route!(site, "/:lang/pricing")
      Gettext.put_locale("en")

      _conn = request(site, "/fa/pricing") |> LanguagePlug.call(opts())

      assert Gettext.get_locale(MishkaCmsCore.Gettext) == "fa"
    end

    # A page published at `/en/admin/dashboard` would otherwise take the dashboard down with it.
    test "a route the CMS does not answer is never moved", %{site: site} do
      prefix_all!(site)
      route!(site, "/en/admin/dashboard")

      conn = request(site, "/admin/dashboard") |> LanguagePlug.call(opts())

      refute conn.halted
      assert conn.status == nil
      assert conn.assigns.site_language == "en"
    end

    # THE ADMIN, AN API CALL, A STYLESHEET: none of them is a page the visitor reads, so the
    # language the next page is read in is still the last page's.
    test "nor does it change the language a visitor is reading in", %{site: site} do
      for mode <- ["prefix_others", "prefix_all"] do
        {:ok, _} = Settings.put("site.language_urls", mode, site_id: site.id)

        conn =
          site
          |> request("/admin/dashboard", %{Languages.session() => "fa"})
          |> LanguagePlug.call(opts())

        assert get_session(conn, Languages.session()) == "fa", mode
        assert conn.assigns.site_language == "fa", mode
        assert Gettext.get_locale(MishkaCmsCore.Gettext) == "fa", mode

        conn = request(site, "/admin/dashboard") |> LanguagePlug.call(opts())

        assert get_session(conn, Languages.session()) == nil, mode
        assert conn.assigns.site_language == "en", mode
      end
    end

    test "nor an address under the primary language the router hands to no CMS route", %{
      site: site
    } do
      conn =
        request(site, "/en/admin/dashboard")
        |> LanguagePlug.call(LanguagePlug.init(router: @router, live_view: SomeOtherLiveView))

      refute conn.halted
      assert conn.status == nil
      assert conn.assigns.site_language == "en"
      assert get_session(conn, Languages.session()) == nil
    end

    test "a request with no site is not this module's business" do
      conn =
        :get |> conn("/admin/dashboard") |> init_test_session(%{}) |> LanguagePlug.call(opts())

      refute conn.halted
      refute conn.assigns[:site_language]
    end
  end

  describe "init/1" do
    test "refuses to start without being told which route the CMS answers" do
      assert_raise ArgumentError, ~r/:router/, fn -> LanguagePlug.init(live_view: @cms) end
      assert_raise ArgumentError, ~r/:live_view/, fn -> LanguagePlug.init(router: @router) end
    end
  end
end
