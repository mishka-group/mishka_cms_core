defmodule MishkaCmsCore.Runtime.LanguagesTest do
  @moduledoc """
  A site's languages, and the one capture name the runtime checks against them.

  The list is what stands between `/:lang/about` and a page that answers `/xyz/about` as though
  somebody had written it in `xyz`, so a list that cannot be read has to come out as the one language
  every page starts in, never as an empty list or a crash.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Settings

  @moduletag :integration

  setup do
    site = create_site!()
    forget_settings(~w(site.languages site.language_urls), [site.id])
    %{site: site}
  end

  # A MASTER BOUNDS EVERY SITE'S LIST. Both settings are global and master-only; the tests set them
  # globally, which is safe only because this module is not async, and forget them on the way out.
  describe "a master's allowed and required languages" do
    setup %{site: site} do
      forget_settings(~w(site.allowed_languages site.required_languages site.languages), [nil])
      {:ok, _} = Settings.put("site.languages", ["en", "fa", "fr"], site_id: site.id)
      :ok
    end

    defp allow!(languages), do: {:ok, _} = Settings.put("site.allowed_languages", languages)
    defp require!(languages), do: {:ok, _} = Settings.put("site.required_languages", languages)

    test "with neither set, a site publishes exactly what it lists", %{site: site} do
      assert Languages.allowed() == []
      assert Languages.required() == []
      assert Languages.site(site.id) == ["en", "fa", "fr"]
    end

    test "a language the master does not allow is not published", %{site: site} do
      allow!(["en", "fa"])

      assert Languages.site(site.id) == ["en", "fa"]
    end

    test "a required language is published whether the site listed it or not", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
      require!(["fa"])

      assert Languages.site(site.id) == ["en", "fa"]
    end

    # The first language is the site's default, so the site's own order is kept.
    test "keeps the site's order, the required ones after its own", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)
      require!(["de", "en"])

      assert Languages.site(site.id) == ["fa", "en", "de"]
    end

    test "a list the bounds empty falls to the required ones, else the first allowed", %{
      site: site
    } do
      {:ok, _} = Settings.put("site.languages", ["fr"], site_id: site.id)
      allow!(["en", "fa"])
      assert Languages.site(site.id) == ["en"]

      require!(["fa"])
      assert Languages.site(site.id) == ["fa"]
    end

    test "the global list is bounded the same way" do
      {:ok, _} = Settings.put("site.languages", ["en", "fr"])
      allow!(["en", "fa"])
      require!(["fa"])

      assert Languages.site(nil) == ["en", "fa"]
    end

    test "the bounds are read from the global rows alone, never a site's", %{site: site} do
      {:ok, _} = Settings.put("site.allowed_languages", ["en"], site_id: site.id)
      forget_settings(~w(site.allowed_languages), [site.id])

      assert Languages.allowed() == []
      assert Languages.site(site.id) == ["en", "fa", "fr"]
    end

    test "a site cannot save a language the master does not allow" do
      allow!(["en", "fa"])

      assert Languages.valid?(["en", "fa"])
      assert Languages.valid?(["FA"])
      refute Languages.valid?(["en", "fr"])
    end

    test "with nothing allowed, any language code can be saved" do
      assert Languages.valid?(["en", "fr", "pt-br"])
    end

    test "a master's own lists may be empty, and must still be codes" do
      assert Languages.codes_or_empty?([])
      assert Languages.codes_or_empty?(["en", "fa"])
      refute Languages.codes_or_empty?(["English"])
      refute Languages.codes_or_empty?("en")
    end
  end

  describe "primary/1 — the language a request that names none is answered in" do
    test "is the first of the site's list", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["fa", "en", "ar"], site_id: site.id)

      assert Languages.primary(site.id) == "fa"
    end

    # There is no second setting to disagree with the list — reordering it IS how the default moves.
    test "follows the list when it is reordered", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      assert Languages.primary(site.id) == "en"

      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)
      assert Languages.primary(site.id) == "fa"
    end

    test "is English for a site that has no list, and for no site at all", %{site: site} do
      assert Languages.primary(site.id) == "en"
      assert Languages.primary(nil) == "en"
    end
  end

  describe "remembered/2 — a session outlives the setting that justified it" do
    test "keeps a language the site still publishes in", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

      assert Languages.remembered("fa", site.id) == "fa"
    end

    # The reason this function exists: a site that drops `fa` would otherwise keep sending everyone
    # who ever chose it to Persian addresses that now answer nothing.
    test "forgets one it has dropped", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      assert Languages.remembered("fa", site.id) == "fa"

      {:ok, _} = Settings.put("site.languages", ["en"], site_id: site.id)
      assert Languages.remembered("fa", site.id) == nil
    end

    test "is nil for anything that is not a language it holds", %{site: site} do
      assert Languages.remembered(nil, site.id) == nil
      assert Languages.remembered("", site.id) == nil
      assert Languages.remembered(:fa, site.id) == nil
      assert Languages.remembered(7, site.id) == nil
    end
  end

  describe "leading/2 — the language a path names" do
    test "is the first segment when the site publishes in it" do
      assert Languages.leading(["fa", "pricing"], ["en", "fa"]) == "fa"
      assert Languages.leading(["en"], ["en", "fa"]) == "en"
    end

    test "is nil for a first segment that is not one of them" do
      assert Languages.leading(["pricing"], ["en", "fa"]) == nil
      assert Languages.leading(["de", "about"], ["en", "fa"]) == nil
      assert Languages.leading(["favicon.ico"], ["en", "fa"]) == nil
    end

    # Only the FIRST segment. `/docs/fa` is a page about Persian, not a page in it.
    test "looks at no other segment" do
      assert Languages.leading(["docs", "fa"], ["en", "fa"]) == nil
    end

    test "is nil for a path with no segments at all" do
      assert Languages.leading([], ["en", "fa"]) == nil
    end
  end

  describe "name/1 — a code in a sentence a person reads" do
    test "is the language's name, whatever the code's case or spacing" do
      assert Languages.name("fa") == "Persian"
      assert Languages.name(" EN ") == "English"
      assert Languages.name(:fr) == "French"
    end

    test "puts a region in brackets" do
      assert Languages.name("pt-br") == "Portuguese (BR)"
    end

    test "is the code itself for a language it has no name for, and nothing for no code" do
      assert Languages.name("xx") == "XX"
      assert Languages.name("") == nil
      assert Languages.name(nil) == nil
    end
  end

  describe "names/1 — several codes as one phrase" do
    test "names each language once, in alphabetical order, the last two joined by and" do
      assert Languages.names(["fa"]) == "Persian"
      assert Languages.names(["fa", "fr"]) == "French and Persian"
      assert Languages.names(["fa", "de", "fr", "fa"]) == "French, German and Persian"
    end

    test "is empty for no languages" do
      assert Languages.names([]) == ""
      assert Languages.names([nil]) == ""
    end
  end

  # A locale with no catalogue reads every message behind its `"[fa] "` marker, and the message the
  # alphabet is read from in reverse, so these tests tell a name that went through Gettext from one
  # that did not, and an order that follows the reader's alphabet from one that follows the code or
  # the English name.
  describe "names in the reader's language" do
    setup do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      :ok
    end

    test "a language's name is translated" do
      assert Languages.name("fa") == "[fa] Persian"
      assert Languages.name("xx") == "XX"
    end

    test "a region follows through the translated template" do
      assert Languages.name("pt-br") == "[fa] [fa] Portuguese (BR)"
    end

    test "several are joined by the translated separator and \"and\"" do
      assert Languages.names(["fa", "fr"]) == "[fa] [fa] Persian and [fa] French"

      assert Languages.names(["fa", "de", "fr"]) ==
               "[fa] [fa] Persian[fa] , [fa] German and [fa] French"
    end

    test "several are put in the order of the reader's alphabet, not of the English one" do
      assert Languages.names(["pt", "fr"]) == "[fa] [fa] Portuguese and [fa] French"

      assert Languages.names(["fr", "pt", "de"]) ==
               "[fa] [fa] Portuguese[fa] , [fa] German and [fa] French"
    end

    test "the same languages are put in the English order when the reader's language is English" do
      Gettext.put_locale(MishkaCmsCore.Gettext, "en")

      assert Languages.names(["pt", "fr"]) == "French and Portuguese"
      assert Languages.names(["fr", "pt", "de"]) == "French, German and Portuguese"
    end
  end

  describe "session/0" do
    test "names the key a visitor's language is remembered under" do
      assert is_binary(Languages.session())
      assert Languages.session() != Languages.capture()
    end
  end

  describe "admin/1 — the language an admin reads the dashboard in" do
    test "is the one the session keeps" do
      assert Languages.admin(%{Languages.admin_session() => "fa"}) == "fa"
    end

    test "is English when the session keeps none" do
      assert Languages.admin(%{}) == "en"
      assert Languages.admin(%{Languages.admin_session() => nil}) == "en"
    end

    test "is kept apart from the language a visitor reads the site in" do
      assert Languages.admin_session() != Languages.session()
      assert Languages.admin(%{Languages.session() => "fa"}) == "en"
    end
  end

  describe "admin_choices/1" do
    test "offers the site's languages, in its order, and English", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["fa", "de"], site_id: site.id)

      assert Languages.admin_choices(site.id) == ["fa", "de", "en"]
    end

    test "offers English once when the site lists it", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)

      assert Languages.admin_choices(site.id) == ["fa", "en"]
    end
  end

  describe "site/1" do
    test "reads the site's own list", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)

      assert Languages.site(site.id) == ["en", "fa", "ar"]
    end

    test "downcases each code and drops what is not a language code", %{site: site} do
      {:ok, _} =
        Settings.put("site.languages", [" FA ", "en", "english", "pt-BR", 7], site_id: site.id)

      assert Languages.site(site.id) == ["fa", "en", "pt-br"]
    end

    test "is English alone when nothing usable is set", %{site: site} do
      {:ok, _} = Settings.put("site.languages", "en, fa", site_id: site.id)
      assert Languages.site(site.id) == ["en"]

      {:ok, _} = Settings.put("site.languages", [], site_id: site.id)
      assert Languages.site(site.id) == ["en"]
    end
  end

  describe "site_named/1" do
    test "reads the list of the site the routing table names" do
      n = System.unique_integer([:positive])
      site = create_site!(name: "languages-#{n}", host: "languages-#{n}.test")
      forget_settings(~w(site.languages), [site.id])
      {:ok, _} = Settings.put("site.languages", ["fa"], site_id: site.id)

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

      assert Languages.site_named(site.name) == ["fa"]
    end

    test "is English alone for a site it does not know" do
      assert Languages.site_named("no-such-site-#{System.unique_integer([:positive])}") == ["en"]
    end
  end

  test "known/0 is every code with a name, sorted, each a valid language code" do
    known = Languages.known()

    assert "en" in known
    assert "fa" in known
    assert known == Enum.sort(Enum.uniq(known))

    for code <- known do
      assert Languages.valid?([code]), code
      refute Languages.name(code) == String.upcase(code), "#{code} has no name"
    end
  end

  test "valid?/1 takes a list of language codes, and nothing less" do
    assert Languages.valid?(["en", " FA ", "pt-br"])
    refute Languages.valid?(["en", "Persian"])
    refute Languages.valid?(["en", 5])
    refute Languages.valid?([])
    refute Languages.valid?("en")
  end

  test "admits?/3 checks a lang capture and nothing else" do
    assert Languages.admits?("lang", "fa", ["en", "fa"])
    refute Languages.admits?("lang", "xyz", ["en", "fa"])
    assert Languages.admits?("slug", "xyz", ["en", "fa"])
  end

  test "captures?/1 finds a lang capture in any segment, as :lang or *lang" do
    assert Languages.captures?("/:lang")
    assert Languages.captures?("/docs/:lang/:section")
    assert Languages.captures?("/shop/:category/:lang")
    assert Languages.captures?("/files/*lang")
    refute Languages.captures?("/fa/about")
    refute Languages.captures?("/:language/about")
    refute Languages.captures?(nil)
  end

  # ONE FUNCTION BUILDS EVERY PUBLIC ADDRESS, so each mode is pinned here once: a link in a
  # template, a page's editions, the sitemap, robots.txt and a redirect all read it.
  describe "url/3 — a stored path's public address" do
    setup %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok
    end

    defp mode!(site, mode),
      do: {:ok, _} = Settings.put("site.language_urls", mode, site_id: site.id)

    test "leaves the primary language unprefixed by default", %{site: site} do
      assert Languages.url_mode(site.id) == "prefix_others"

      assert Languages.url("/:lang/blog", %{"lang" => "en"}, site.id) == "/blog"
      assert Languages.url("/:lang/blog", %{"lang" => "fa"}, site.id) == "/fa/blog"
      assert Languages.url("/:lang", %{"lang" => "en"}, site.id) == "/"
      assert Languages.url("/:lang", %{"lang" => "fa"}, site.id) == "/fa"
    end

    test "drops a literal first segment that is the primary language, and only that one", %{
      site: site
    } do
      assert Languages.url("/en/pricing", %{}, site.id) == "/pricing"
      assert Languages.url("/en", %{}, site.id) == "/"
      assert Languages.url("/fa/pricing", %{}, site.id) == "/fa/pricing"
      assert Languages.url("/pricing", %{}, site.id) == "/pricing"
      assert Languages.url("/", %{}, site.id) == "/"

      # A lang anywhere but the first segment is an ordinary capture.
      assert Languages.url("/docs/:lang/intro", %{"lang" => "en"}, site.id) == "/docs/en/intro"
      assert Languages.url("/docs/en", %{}, site.id) == "/docs/en"
    end

    test "prefixes every language in prefix_all", %{site: site} do
      mode!(site, "prefix_all")

      assert Languages.url_mode(site.id) == "prefix_all"
      assert Languages.url("/:lang/blog", %{"lang" => "en"}, site.id) == "/en/blog"
      assert Languages.url("/:lang", %{"lang" => "en"}, site.id) == "/en"
      assert Languages.url("/en/pricing", %{}, site.id) == "/en/pricing"
    end

    test "follows the site's first language", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)

      assert Languages.url("/:lang/blog", %{"lang" => "fa"}, site.id) == "/blog"
      assert Languages.url("/:lang/blog", %{"lang" => "en"}, site.id) == "/en/blog"
    end

    test "is nil for a language the site does not publish, or a capture it is not given", %{
      site: site
    } do
      refute Languages.url("/:lang/blog", %{"lang" => "de"}, site.id)
      refute Languages.url("/:lang/blog", %{}, site.id)
      refute Languages.url("/:lang/blog/:slug", %{"lang" => "fa"}, site.id)

      # A literal path names no capture to hold to the list.
      assert Languages.url("/de/about", %{}, site.id) == "/de/about"
    end

    test "fills every capture, percent-encoding each and each segment of a rest", %{site: site} do
      captures = %{"lang" => "fa", "slug" => "hello world", "rest" => "a b/c"}

      assert Languages.url("/:lang/blog/:slug", captures, site.id) == "/fa/blog/hello%20world"
      assert Languages.url("/:lang/docs/*rest", captures, site.id) == "/fa/docs/a%20b/c"

      assert Languages.url("/:lang/blog/:slug", %{captures | "lang" => "en"}, site.id) ==
               "/blog/hello%20world"
    end

    test "fills a capture in any segment, a rest across several, and keeps every literal", %{
      site: site
    } do
      mode!(site, "prefix_all")

      assert Languages.url(
               "/docs/:lang/:section",
               %{"lang" => "fa", "section" => "setup"},
               site.id
             ) ==
               "/docs/fa/setup"

      assert Languages.url(
               "/shop/:category/:lang",
               %{"category" => "books", "lang" => "en"},
               site.id
             ) ==
               "/shop/books/en"

      assert Languages.url("/files/*rest", %{"rest" => "a/b c"}, site.id) == "/files/a/b%20c"
      assert Languages.url("/about", %{}, site.id) == "/about"
      assert Languages.url("/", %{}, site.id) == "/"
      refute Languages.url("/files/*rest", %{"rest" => ""}, site.id)
    end

    test "url/4 builds in the mode it is given, whatever the site's", %{site: site} do
      mode!(site, "prefix_all")

      assert Languages.url("/:lang/blog", %{"lang" => "en"}, site.id, "prefix_others") == "/blog"
      assert Languages.url("/en/blog", %{}, site.id, "prefix_others") == "/blog"
    end

    test "a value that is no mode reads prefix_others", %{site: site} do
      mode!(site, "sideways")

      assert Languages.url_mode(site.id) == "prefix_others"
      assert Languages.url_modes() == ["prefix_others", "prefix_all"]
    end
  end

  describe "implied/2 — the language of an address that names none" do
    setup %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      :ok
    end

    test "is the primary language while the site leaves it unprefixed", %{site: site} do
      assert Languages.implied(["blog"], site.id) == "en"
      assert Languages.implied([], site.id) == "en"
      assert Languages.implied(["de", "about"], site.id) == "en"
    end

    test "is nil for an address that names one of the site's languages", %{site: site} do
      refute Languages.implied(["fa", "blog"], site.id)
      refute Languages.implied(["en", "blog"], site.id)
    end

    test "is nil when every language is prefixed", %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      refute Languages.implied(["blog"], site.id)
    end
  end

  test "direction/1 reads a language's primary subtag" do
    for rtl <- ~w(ar fa he ur fa-IR) do
      assert Languages.direction(rtl) == "rtl", "#{rtl} is written right to left"
    end

    for ltr <- ["en", "ru", "en-gb", nil] do
      assert Languages.direction(ltr) == "ltr"
    end
  end
end
