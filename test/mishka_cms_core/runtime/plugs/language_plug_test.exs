defmodule MishkaCmsCore.Runtime.Plugs.LanguagePlugTest do
  @moduledoc """
  Every request lands on an address that names the language it is answered in, and no request that
  is not the CMS's to answer is moved.

  The rule is asked of the routing table rather than of a list of exceptions, so what it leaves
  alone — a page stored without a language, a route Phoenix owns — is decided by the same lookup the
  request itself is about to make.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Plugs.LanguagePlug
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  @moduletag :integration

  @router MishkaCmsCore.TestRouter
  @cms MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index

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

    forget_settings(~w(site.languages), [site.id])
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

  describe "target/3 — where a request belongs" do
    test "a first segment that is one of the site's languages is the answer", %{where: where} do
      assert LanguagePlug.target(["fa", "pricing"], where, nil) == {:serve, "fa"}
      assert LanguagePlug.target(["en"], where, "fa") == {:serve, "en"}
    end

    test "a segment that only looks like a language is not one", %{site: site, where: where} do
      route!(site, "/de/about")

      assert LanguagePlug.target(["de", "about"], where, nil) == {:serve, "en"}
    end

    test "a page stored without a language keeps its address", %{site: site, where: where} do
      route!(site, "/no-lang")

      assert LanguagePlug.target(["no-lang"], where, nil) == {:serve, "en"}
    end

    test "a page that resolves only under a language is sent there", %{site: site, where: where} do
      route!(site, "/:lang/blog")

      assert LanguagePlug.target(["blog"], where, nil) == {:redirect, "/en/blog", "en"}
    end

    test "the root is sent to the site's first language", %{site: site, where: where} do
      route!(site, "/:lang")

      assert LanguagePlug.target([], where, nil) == {:redirect, "/en", "en"}
    end

    test "a remembered language is where a visitor is sent", %{site: site, where: where} do
      route!(site, "/:lang/blog")

      assert LanguagePlug.target(["blog"], where, "fa") == {:redirect, "/fa/blog", "fa"}
    end

    # A visitor who once chose Persian asking for an address that names no language is not asking
    # for Persian — and sending them to a Persian page nobody wrote is a 404 a visitor with no
    # session at all does not get.
    test "a remembered language the page has no edition in falls back to the site's first",
         %{site: site, where: where} do
      route!(site, "/:lang/blog", "en")

      assert LanguagePlug.target(["blog"], where, "fa") == {:redirect, "/en/blog", "en"}
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
               {:redirect, "/fa/blog", "fa"}
    end
  end

  describe "init/1" do
    test "refuses to start without being told which route the CMS answers" do
      assert_raise ArgumentError, ~r/:router/, fn -> LanguagePlug.init(live_view: @cms) end
      assert_raise ArgumentError, ~r/:live_view/, fn -> LanguagePlug.init(router: @router) end
    end
  end
end
