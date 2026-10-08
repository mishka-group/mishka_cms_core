defmodule MishkaCmsCore.Runtime.States.LangCaptureTest do
  @moduledoc """
  A pattern's `lang` capture matches only one of its site's languages, in whichever segment it sits.

  Every other capture keeps taking whatever the visitor asked for, and a request whose `lang` is not
  the site's goes on to the next pattern that matches it, or to nothing — never to a page rendered in
  a language nobody wrote it in.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  @moduletag :integration

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "lang-capture-#{n}", host: "lang-capture-#{n}.test")

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

    %{site: site}
  end

  defp route!(site, id, path, priority \\ 0, language \\ nil) do
    :ok =
      WebRunTimeMetaDataState.save(%{
        id: id,
        site: site.name,
        path: path,
        title: id,
        created_at: DateTime.utc_now(),
        section: "Page",
        priority: priority,
        language: language
      })
  end

  defp resolve(site, path), do: WebRunTimeMetaDataState.resolve(path, site.name)

  # THE PRIMARY LANGUAGE UNPREFIXED, the default: an address whose first segment is not one of the
  # site's languages is read as the primary language's.
  describe "an address that names no language" do
    test "is the page under the primary language, which it captures", %{site: site} do
      route!(site, "blog", "/:lang/blog")
      route!(site, "home", "/:lang")

      assert {:ok, %{id: "blog"}, %{"lang" => "en"}} = resolve(site, "/blog")
      assert {:ok, %{id: "home"}, %{"lang" => "en"}} = resolve(site, "/")
      assert {:ok, %{id: "blog"}, %{"lang" => "fa"}} = resolve(site, "/fa/blog")
    end

    test "is a literal page as typed first, then one stored under the primary language", %{
      site: site
    } do
      route!(site, "prefixed", "/en/pricing")
      assert {:ok, %{id: "prefixed"}, captured} = resolve(site, "/pricing")
      assert captured == %{}

      route!(site, "as-typed", "/pricing")
      assert {:ok, %{id: "as-typed"}, _captured} = resolve(site, "/pricing")

      route!(site, "pattern", "/:lang/about")
      route!(site, "literal", "/en/about")
      assert {:ok, %{id: "literal"}, _captured} = resolve(site, "/about")
    end

    test "takes the best pattern of either form, the prefixed one winning a tie", %{site: site} do
      route!(site, "by-slug", "/:slug")
      route!(site, "about", "/:lang/about")
      route!(site, "anything", "/:lang/*rest")

      assert {:ok, %{id: "about"}, %{"lang" => "en"}} = resolve(site, "/about")
      assert {:ok, %{id: "by-slug"}, %{"slug" => "news"}} = resolve(site, "/news")
      assert {:ok, %{id: "anything"}, %{"rest" => "news/today"}} = resolve(site, "/news/today")
    end

    test "is not the page of a language the page was not written in", %{site: site} do
      route!(site, "about-fa", "/:lang/about", 0, "fa")

      assert resolve(site, "/about") == {:error, :not_found}
      assert {:ok, %{id: "about-fa"}, _captured} = resolve(site, "/fa/about")
    end

    test "is asked about as typed alone when every language is prefixed", %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)
      route!(site, "blog", "/:lang/blog")
      route!(site, "prefixed", "/en/pricing")

      assert resolve(site, "/blog") == {:error, :not_found}
      assert resolve(site, "/pricing") == {:error, :not_found}
      assert {:ok, %{id: "blog"}, %{"lang" => "en"}} = resolve(site, "/en/blog")
    end
  end

  test "answers only the site's languages, first, middle or last", %{site: site} do
    route!(site, "first", "/:lang/about")
    route!(site, "middle", "/docs/:lang/:section")
    route!(site, "last", "/shop/:category/:lang")

    assert {:ok, %{id: "first"}, %{"lang" => "fa"}} = resolve(site, "/fa/about")

    assert {:ok, %{id: "middle"}, %{"lang" => "en", "section" => "setup"}} =
             resolve(site, "/docs/en/setup")

    assert {:ok, %{id: "last"}, %{"lang" => "fa", "category" => "books"}} =
             resolve(site, "/shop/books/fa")

    for path <- ~w(/xyz/about /docs/xyz/setup /shop/books/xyz /FA/about) do
      assert resolve(site, path) == {:error, :not_found},
             "#{path} answered a language the site lacks"
    end
  end

  test "and a rest capture named lang the same way", %{site: site} do
    route!(site, "rest", "/files/*lang")

    assert {:ok, %{id: "rest"}, %{"lang" => "fa"}} = resolve(site, "/files/fa")
    assert resolve(site, "/files/fa/extra") == {:error, :not_found}
  end

  test "a request it refuses goes on to the next pattern", %{site: site} do
    route!(site, "by-language", "/:lang/guide", 10)
    route!(site, "by-slug", "/:slug/guide")

    assert {:ok, %{id: "by-language"}, _captured} = resolve(site, "/fa/guide")
    assert {:ok, %{id: "by-slug"}, %{"slug" => "xyz"}} = resolve(site, "/xyz/guide")
  end

  test "reads each site's own list", %{site: site} do
    n = System.unique_integer([:positive])
    other = create_site!(name: "lang-capture-other-#{n}", host: "lang-capture-other-#{n}.test")

    :ok =
      SiteState.save(%{
        id: other.id,
        name: other.name,
        host: other.host,
        priority: other.priority,
        active: other.active,
        master: other.master
      })

    forget_settings(~w(site.languages), [other.id])
    {:ok, _} = Settings.put("site.languages", ["ar"], site_id: other.id)

    on_exit(fn ->
      WebRunTimeMetaDataState.delete_by_site(other.name)
      SiteState.delete(other.id)
    end)

    route!(site, "mine", "/:lang/team")
    route!(other, "theirs", "/:lang/team")

    assert {:ok, %{id: "mine"}, _} = resolve(site, "/fa/team")
    assert resolve(other, "/fa/team") == {:error, :not_found}
    assert {:ok, %{id: "theirs"}, _} = resolve(other, "/ar/team")
  end

  # THE PATTERN'S OWN TEXT IS NOT AN ADDRESS. A pattern page is stored under its pattern and the path
  # index is keyed by the stored string, so `/:lang/blog` typed into the address bar matched that
  # index EXACTLY and was served as a literal page — 200, in no language, with nothing captured and
  # the matcher below never consulted. That is why `/xyz/blog` was refused all along and the one
  # spelling that should have been impossible got through.
  test "a request spelled like the pattern itself is refused", %{site: site} do
    route!(site, "blog", "/:lang/blog")
    route!(site, "tags", "/:lang/blog/tags")

    assert {:ok, %{id: "blog"}, %{"lang" => "en"}} = resolve(site, "/en/blog")
    assert {:ok, %{id: "tags"}, %{"lang" => "fa"}} = resolve(site, "/fa/blog/tags")

    assert resolve(site, "/:lang/blog") == {:error, :not_found}
    assert resolve(site, "/:lang/blog/tags") == {:error, :not_found}
  end

  # AND EVERY OTHER CAPTURE WITH IT. `lang` is the only one with a list to check against, so a
  # slug-shaped capture would take the word `:slug` as a slug and render the page around it.
  test "and so is one spelled like any other capture", %{site: site} do
    route!(site, "post", "/post/:slug")
    route!(site, "docs", "/docs/*rest")

    assert {:ok, %{id: "post"}, %{"slug" => "hello"}} = resolve(site, "/post/hello")
    assert {:ok, %{id: "docs"}, %{"rest" => "a/b"}} = resolve(site, "/docs/a/b")

    assert resolve(site, "/post/:slug") == {:error, :not_found}
    assert resolve(site, "/docs/*rest") == {:error, :not_found}
  end

  # WHAT THE GUARD MUST NOT COST. A layout is reached by the path the page names it with, not by a
  # URL anyone typed, so a stored path is still looked up as written — including a pattern one.
  test "while a caller naming a stored path still finds it", %{site: site} do
    :ok =
      WebRunTimeMetaDataState.save(%{
        id: "layout",
        site: site.name,
        path: "/:lang/layouts/main",
        title: "layout",
        created_at: DateTime.utc_now(),
        section: "Layout",
        priority: 0
      })

    assert {:ok, %{id: "layout"}} =
             WebRunTimeMetaDataState.find_by_path_and_site("/:lang/layouts/main", site.name)
  end

  # A PAGE ANSWERS ITS OWN LANGUAGE AND NO OTHER — the half `admits?/3` never covered. That one asks
  # whether the SITE speaks the language; this asks whether THIS PAGE was written in it. A site that
  # publishes Persian answered `/fa/about` out of the English row for as long as the row was the only
  # one, which is a page rendered in a language nobody wrote it in — the very thing this file's
  # moduledoc says never happens.
  describe "a page and the language it was written in" do
    test "answers the language it is written in", %{site: site} do
      route!(site, "about-en", "/:lang/about", 0, "en")

      assert {:ok, %{id: "about-en"}, %{"lang" => "en"}} = resolve(site, "/en/about")
    end

    test "and not another of the site's languages it has no edition in", %{site: site} do
      route!(site, "about-en", "/:lang/about", 0, "en")

      assert resolve(site, "/fa/about") == {:error, :not_found},
             "the English page answered a Persian address"
    end

    # THE EDITION IS A ROW OF ITS OWN, and `PageEditions.translation_path/2` gives it a LITERAL path.
    # `stored_or_dynamic/2` answers an exact path before the pattern matcher runs, so the Persian
    # edition is found without the language rule being consulted at all.
    test "the edition itself answers, by its own literal path", %{site: site} do
      route!(site, "about-en", "/:lang/about", 0, "en")
      route!(site, "about-fa", "/fa/about", 0, "fa")

      assert {:ok, %{id: "about-fa"}, %{}} = resolve(site, "/fa/about")
      assert {:ok, %{id: "about-en"}, %{"lang" => "en"}} = resolve(site, "/en/about")
    end

    # A LITERAL PATH IS NOT ASKING ABOUT LANGUAGES AT ALL. `fr` is not one of this site's languages —
    # `admits?/3` would refuse it in a pattern — but a row written at that address answers because
    # the address is what it is. A second project's `/fr/blog/tags` is somebody's real page.
    test "a literal path answers even in a language the site never declared", %{site: site} do
      route!(site, "tags-fr", "/fr/blog/tags", 0, "fr")

      assert {:ok, %{id: "tags-fr"}, %{}} = resolve(site, "/fr/blog/tags")
    end

    test "while the same address as a pattern is refused that language", %{site: site} do
      route!(site, "tags-en", "/:lang/blog/tags", 0, "en")

      assert resolve(site, "/fr/blog/tags") == {:error, :not_found}
    end

    # REJECTED IS NOT FOUND-AND-REFUSED. A candidate dropped for its language leaves the field to a
    # less specific pattern, which is the fall-through this resolver has always had.
    test "a refused edition still falls through to a pattern that fits", %{site: site} do
      route!(site, "guide-en", "/:lang/guide", 0, "en")
      route!(site, "any-guide", "/:slug/guide", 0, nil)

      assert {:ok, %{id: "any-guide"}, %{"slug" => "fa"}} = resolve(site, "/fa/guide")
    end

    # A LAYOUT IS NOT AN EDITION OF ANYTHING. Rows that carry no language keep answering whatever the
    # URL captured, which is every row this table held before pages had a language at all.
    test "a row with no language answers any of the site's languages", %{site: site} do
      route!(site, "langless", "/:lang/legacy", 0, nil)

      assert {:ok, %{id: "langless"}, %{"lang" => "en"}} = resolve(site, "/en/legacy")
      assert {:ok, %{id: "langless"}, %{"lang" => "fa"}} = resolve(site, "/fa/legacy")
    end
  end
end
