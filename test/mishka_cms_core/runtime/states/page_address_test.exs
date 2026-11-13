# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.States.PageAddressTest do
  @moduledoc """
  The addresses a site keeps when it moves from WordPress: paths in any script, every page that
  matches an address in the order it is tried, and the page a kind of record is shown on.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  @moduletag :integration

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "page-address-#{n}", host: "page-address-#{n}.test")

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
    {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)

    on_exit(fn ->
      WebRunTimeMetaDataState.delete_by_site(site.name)
      SiteState.delete(site.id)
    end)

    %{site: site}
  end

  defp route!(site, id, path, opts \\ []) do
    :ok =
      WebRunTimeMetaDataState.save(%{
        id: id,
        site: site.name,
        path: path,
        title: id,
        created_at: DateTime.utc_now(),
        section: Keyword.get(opts, :section, "Page"),
        priority: Keyword.get(opts, :priority, 0),
        language: Keyword.get(opts, :language),
        record: Keyword.get(opts, :record)
      })
  end

  defp ids(site, path),
    do:
      site
      |> then(&WebRunTimeMetaDataState.resolve_all(path, &1.name))
      |> Enum.map(&elem(&1, 0).id)

  describe "a path in Persian or Arabic" do
    test "is reached decoded, %-escaped and in another composition", %{site: site} do
      route!(site, "wordpress", "/fa/وردپرس")
      route!(site, "news", "/ar/أخبار")

      for path <- ["/fa/وردپرس", "/fa/%D9%88%D8%B1%D8%AF%D9%BE%D8%B1%D8%B3"] do
        assert {:ok, %{id: "wordpress"}, %{}} = WebRunTimeMetaDataState.resolve(path, site.name)
      end

      assert {:ok, %{id: "news"}, %{}} =
               WebRunTimeMetaDataState.resolve("/ar/أخبار", site.name)
    end

    test "is captured decoded by a pattern", %{site: site} do
      route!(site, "post", "/fa/blog/:slug")

      assert {:ok, %{id: "post"}, %{"slug" => "سلام"}} =
               WebRunTimeMetaDataState.resolve("/fa/blog/%D8%B3%D9%84%D8%A7%D9%85", site.name)
    end

    test "an escape that is not UTF-8 answers nothing", %{site: site} do
      route!(site, "post", "/fa/blog/:slug")
      assert {:error, :not_found} = WebRunTimeMetaDataState.resolve("/fa/%FF", site.name)
    end
  end

  describe "every page that answers an address" do
    test "is ranked as the first one is picked, each with its own captures", %{site: site} do
      route!(site, "any", "/*rest")
      route!(site, "post", "/:year/:month/:slug", priority: 5)
      route!(site, "page", "/:a/:b/:c", priority: 1)

      assert ids(site, "/2024/05/hello") == ["post", "page", "any"]

      assert [{_post, %{"slug" => "hello"}}, {_page, %{"c" => "hello"}}, {_any, %{"rest" => _}}] =
               WebRunTimeMetaDataState.resolve_all("/2024/05/hello", site.name)
    end

    test "is the literal page alone when one is stored there", %{site: site} do
      route!(site, "pattern", "/:slug")
      route!(site, "about", "/about")

      assert ids(site, "/about") == ["about"]
      assert ids(site, "/contact") == ["pattern"]
    end

    test "keeps to one section when asked for it, and raises the 404 when none is left", %{
      site: site
    } do
      route!(site, "layout", "/:slug", section: "Layout")
      route!(site, "any", "/*rest")

      assert [{%{id: "any"}, _captured}] =
               WebRunTimeMetaDataState.resolve_all!("/hello", site.name, "Page")

      assert_raise MishkaCmsCore.ErrorsExceptions.NotFoundError, fn ->
        WebRunTimeMetaDataState.resolve_all!("/hello", site.name, "ErrorPage")
      end
    end
  end

  describe "a *name in the middle of a path" do
    test "takes the fewest segments, at least one, that let the rest match", %{site: site} do
      route!(site, "post", "/:lang/*category/:slug")

      assert {:ok, %{id: "post"}, %{"lang" => "en", "category" => "news", "slug" => "my-post"}} =
               WebRunTimeMetaDataState.resolve("/en/news/my-post", site.name)

      assert {:ok, %{id: "post"}, %{"category" => "design/accessibility", "slug" => "my-post"}} =
               WebRunTimeMetaDataState.resolve("/en/design/accessibility/my-post", site.name)

      assert {:error, :not_found} = WebRunTimeMetaDataState.resolve("/en/my-post", site.name)
    end

    test "with a fixed segment after it, stops at the first place that segment matches", %{
      site: site
    } do
      route!(site, "edit", "/docs/*chain/edit")

      assert {:ok, %{id: "edit"}, %{"chain" => "a/b"}} =
               WebRunTimeMetaDataState.resolve("/docs/a/b/edit", site.name)

      assert {:ok, %{id: "edit"}, %{"chain" => "edit/x"}} =
               WebRunTimeMetaDataState.resolve("/docs/edit/x/edit", site.name)

      assert {:error, :not_found} = WebRunTimeMetaDataState.resolve("/docs/a/b", site.name)
    end

    test "captures a Persian chain decoded, typed or %-escaped", %{site: site} do
      route!(site, "post", "/:lang/*category/:slug")

      for path <- [
            "/fa/طراحی/دسترسی/نوشته",
            "/fa/" <> URI.encode("طراحی/دسترسی/نوشته")
          ] do
        assert {:ok, %{id: "post"}, %{"category" => "طراحی/دسترسی", "slug" => "نوشته"}} =
                 WebRunTimeMetaDataState.resolve(path, site.name)
      end
    end

    test "ranks behind a literal page and a pattern with fewer wildcards", %{site: site} do
      route!(site, "post", "/:lang/*category/:slug")
      route!(site, "blog", "/:lang/blog/:slug")
      route!(site, "news", "/en/blog/news")

      assert ids(site, "/en/blog/news") == ["news"]
      assert ids(site, "/en/blog/hello") == ["blog", "post"]
      assert ids(site, "/en/design/ux/hello") == ["post"]
    end

    test "is matched from memory, with no query", %{site: site} do
      route!(site, "post", "/:lang/*category/:slug")

      handler = "mid-wildcard-#{System.unique_integer([:positive])}"
      test = self()

      :telemetry.attach(
        handler,
        [:mishka_cms_core, :repo, :query],
        fn _event, _measurements, meta, _config -> send(test, {handler, meta[:query]}) end,
        nil
      )

      try do
        assert {:ok, %{id: "post"}, _captured} =
                 WebRunTimeMetaDataState.resolve("/en/a/b/c/hello", site.name)
      after
        :telemetry.detach(handler)
      end

      refute_received {^handler, _query}
    end
  end

  describe "path_for_record/3" do
    test "is the path of the page written in the language asked, then one for every language", %{
      site: site
    } do
      route!(site, "all", "/:lang/blog/:slug", record: "blog:post")
      route!(site, "fa", "/fa/نوشته/:slug", record: "blog:post", language: "fa")
      route!(site, "tag", "/:lang/tag/:slug", record: "blog:tag")

      assert {:ok, "/fa/نوشته/:slug"} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:post", "fa")

      assert {:ok, "/:lang/blog/:slug"} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:post", "en")

      assert {:ok, "/:lang/blog/:slug"} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:post")

      assert {:ok, "/:lang/tag/:slug"} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:tag", "fa")
    end

    test "is not a page in another language, nor one that is gone", %{site: site} do
      route!(site, "fa", "/fa/blog/:slug", record: "blog:post", language: "fa")

      assert {:error, :not_found} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:post", "en")

      assert {:error, :not_found} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:category")

      :ok = WebRunTimeMetaDataState.delete("fa")

      assert {:error, :not_found} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:post", "fa")
    end

    test "follows a page whose path or record changed", %{site: site} do
      route!(site, "post", "/blog/:slug", record: "blog:post")
      route!(site, "post", "/posts/:slug", record: "blog:post")

      assert {:ok, "/posts/:slug"} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:post")

      route!(site, "post", "/posts/:slug", record: nil)

      assert {:error, :not_found} =
               WebRunTimeMetaDataState.path_for_record(site.name, "blog:post")
    end
  end
end
