defmodule MishkaCmsCore.Runtime.PageEditionsTest do
  @moduledoc """
  A page in its other languages, built from the page's own path and captures.

  Nothing here assumes the language is the first segment. A pattern page may capture `lang` first,
  in the middle or last, beside other captures, and every URL it makes in another language is that
  same pattern with only the `lang` capture swapped.

  A translation is also a page of its own rather than a second view of one, which is what the
  element CSS block at the end pins: it is edited in the builder, so its elements have to be its own.
  """
  use MishkaCmsCore.DataCase, async: false

  require Ash.Query

  alias MishkaCmsCore.Runtime.{Page, PageEditions, PageProvision, Stylesheet}
  alias MishkaCmsCore.Runtime.PageBuilder.ElementCss
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Settings

  @moduletag :integration

  # The mark an extension's page carries: its template reads the captured language, so it answers
  # every one the site has. A page without it answers its own — see `PageEditions.served_languages/2`.
  @every_language %{"serves_all_languages" => true}

  setup do
    site = create_site!()
    forget_settings(~w(site.languages), [site.id])
    {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)
    %{site: site}
  end

  defp editions(page, site) do
    page
    |> Map.take([:path, :language, :language_group_id, :extra])
    |> PageEditions.editions(site.id)
  end

  describe "path/2" do
    test "fills a capture in any segment, and a rest capture across several" do
      assert PageEditions.path("/:lang", %{"lang" => "fa"}) == "/fa"

      assert PageEditions.path("/docs/:lang/:section", %{"lang" => "ar", "section" => "setup"}) ==
               "/docs/ar/setup"

      assert PageEditions.path("/shop/:category/:lang", %{"category" => "books", "lang" => "en"}) ==
               "/shop/books/en"

      assert PageEditions.path("/files/*rest", %{"rest" => "a/b c"}) == "/files/a/b%20c"
      assert PageEditions.path("/about", %{}) == "/about"
      assert PageEditions.path("/", %{}) == "/"
    end

    test "is nil when the captures do not hold one the path needs" do
      assert PageEditions.path("/post/:slug", %{"lang" => "fa"}) == nil
      assert PageEditions.path("/files/*rest", %{"rest" => ""}) == nil
    end
  end

  describe "language/2" do
    test "is the captured lang on a page whose path captures one" do
      assert PageEditions.language(%{path: "/docs/:lang", language: "en"}, %{"lang" => "fa"}) ==
               "fa"
    end

    test "and the page's own language everywhere else" do
      assert PageEditions.language(%{path: "/fa/about", language: "fa"}, %{}) == "fa"
      assert PageEditions.language(%{path: "/:slug", language: "ar"}, %{"lang" => "fa"}) == "ar"
    end
  end

  describe "translation_path/2" do
    test "prefixes a path that names no language" do
      assert PageEditions.translation_path(%{path: "/about", language: "en"}, "fa") == "/fa/about"
      assert PageEditions.translation_path(%{path: "/", language: "en"}, "fa") == "/fa"
    end

    test "swaps a literal segment naming the page's language, wherever it sits" do
      assert PageEditions.translation_path(%{path: "/docs/en/intro", language: "en"}, "fa") ==
               "/docs/fa/intro"
    end

    test "swaps the lang capture, keeping every other one" do
      assert PageEditions.translation_path(%{path: "/:lang/post/:slug", language: "en"}, "fa") ==
               "/fa/post/:slug"

      assert PageEditions.translation_path(%{path: "/shop/:category/:lang", language: "en"}, "ar") ==
               "/shop/:category/ar"
    end
  end

  describe "alternates/3 of editions/2" do
    test "lists a group's active literal editions, the same from each of them", %{site: site} do
      master = create_page!(site_id: site.id, name: "about", path: "/about")

      fa =
        create_page!(
          site_id: site.id,
          name: "about-fa",
          path: "/fa/about",
          language: "fa",
          language_group_id: master.id
        )

      create_page!(
        site_id: site.id,
        name: "about-ar",
        path: "/ar/about",
        language: "ar",
        language_group_id: master.id,
        active: false
      )

      expected = [%{language: "en", path: "/about"}, %{language: "fa", path: "/fa/about"}]

      assert PageEditions.alternates(editions(master, site), %{}, site.id) == expected
      assert PageEditions.alternates(editions(fa, site), %{}, site.id) == expected
    end

    test "swaps the lang capture of a pattern page, first, middle or last", %{site: site} do
      for {path, url} <- [
            {"/:lang/guide", &"/#{&1}/guide"},
            {"/docs/:lang/setup", &"/docs/#{&1}/setup"},
            {"/shop/books/:lang", &"/shop/books/#{&1}"}
          ] do
        page = create_page!(site_id: site.id, path: path, extra: @every_language)

        assert PageEditions.alternates(editions(page, site), %{"lang" => "fa"}, site.id) ==
                 Enum.map(~w(ar en fa), &%{language: &1, path: url.(&1)}),
               "#{path} did not make the same page in each language"
      end
    end

    test "offers nothing for a pattern that captures more than the language", %{site: site} do
      for {path, captured} <- [
            {"/:lang/blog/:slug", %{"lang" => "fa", "slug" => "my-post"}},
            {"/guides/:lang/*rest", %{"lang" => "fa", "rest" => "setup/linux"}},
            {"/shop/:category/:lang", %{"category" => "books", "lang" => "fa"}}
          ] do
        page = create_page!(site_id: site.id, path: path)

        assert PageEditions.alternates(editions(page, site), captured, site.id) == [],
               "#{path} offered a language at a capture belonging to the one being left"
      end
    end

    test "names the URL it is serving when a literal translation answers for it", %{site: site} do
      master = create_page!(site_id: site.id, name: "post", path: "/:lang/blog/:slug")

      create_page!(
        site_id: site.id,
        name: "post-fa",
        path: "/fa/blog/neveshte",
        language: "fa",
        language_group_id: master.id
      )

      assert PageEditions.alternates(
               editions(master, site),
               %{"lang" => "en", "slug" => "my-post"},
               site.id
             ) == [
               %{language: "en", path: "/en/blog/my-post"},
               %{language: "fa", path: "/fa/blog/neveshte"}
             ]
    end

    test "prefers a literal edition to its pattern master for that language", %{site: site} do
      master =
        create_page!(
          site_id: site.id,
          name: "guide",
          path: "/:lang/guide",
          extra: @every_language
        )

      create_page!(
        site_id: site.id,
        name: "guide-fa",
        path: "/fa/rahnama",
        language: "fa",
        language_group_id: master.id
      )

      assert PageEditions.alternates(editions(master, site), %{"lang" => "en"}, site.id) == [
               %{language: "ar", path: "/ar/guide"},
               %{language: "en", path: "/en/guide"},
               %{language: "fa", path: "/fa/rahnama"}
             ]
    end

    test "is empty for a page in one language", %{site: site} do
      page = create_page!(site_id: site.id, path: "/alone")

      assert PageEditions.alternates(editions(page, site), %{}, site.id) == []
    end

    # `/:lang/about` WRITTEN IN ENGLISH ANSWERS `/en/about` AND NOTHING ELSE: the resolver refuses
    # `/fa/about` to it. Offering that URL was a link to a 404, in the head and in a language switcher.
    test "swaps a pattern page not marked for every language into its own alone", %{site: site} do
      page = create_page!(site_id: site.id, name: "about", path: "/:lang/about")

      assert PageEditions.alternates(editions(page, site), %{"lang" => "en"}, site.id) == []

      create_page!(
        site_id: site.id,
        name: "about-fa",
        path: "/fa/about",
        language: "fa",
        language_group_id: page.id
      )

      assert PageEditions.alternates(editions(page, site), %{"lang" => "en"}, site.id) == [
               %{language: "en", path: "/en/about"},
               %{language: "fa", path: "/fa/about"}
             ]
    end
  end

  describe "served_languages/2" do
    test "is every language of the site for a page marked as serving them all", %{site: site} do
      page = create_page!(site_id: site.id, path: "/:lang/blog", extra: @every_language)

      assert PageEditions.served_languages(page, site.id) == ~w(en fa ar)
    end

    test "is its own language alone for a page not marked", %{site: site} do
      page = create_page!(site_id: site.id, path: "/:lang/about", language: "fa")

      assert PageEditions.served_languages(page, site.id) == ["fa"]
    end

    test "is none for a page in a language the site does not list", %{site: site} do
      page = create_page!(site_id: site.id, path: "/:lang/ueber", language: "de")

      assert PageEditions.served_languages(page, site.id) == []
    end

    test "is its own language for a path that captures none, listed or not", %{site: site} do
      page = create_page!(site_id: site.id, path: "/de/ueber", language: "de")

      assert PageEditions.served_languages(page, site.id) == ["de"]
    end

    # THE MARK A COMPILED PAGE CARRIES has had its key atomized wherever the atom exists — and this
    # module names it, so here it does.
    test "reads the mark off a compiled page's extra", %{site: site} do
      page = %{path: "/:lang/blog", language: "en", extra: %{serves_all_languages: true}}

      assert PageEditions.served_languages(page, site.id) == ~w(en fa ar)
    end

    # THE ONE RULE, the resolver's and this: each page's routing row is saved the way the compile
    # worker saves it, and every language the site lists is asked for at the page's pattern.
    test "is the languages the resolver answers the page in" do
      n = System.unique_integer([:positive])
      site = create_site!(name: "served-#{n}", host: "served-#{n}.test")
      forget_settings(~w(site.languages), [site.id])
      {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)
      :ok = SiteState.save(Map.take(site, [:id, :name, :host, :priority, :active, :master]))

      on_exit(fn ->
        WebRunTimeMetaDataState.delete_by_site(site.name)
        SiteState.delete(site.id)
      end)

      for {language, extra} <- [{"en", @every_language}, {"fa", %{}}, {"de", %{}}] do
        page =
          create_page!(
            site_id: site.id,
            path: "/:lang/#{language}-page",
            language: language,
            extra: extra
          )

        id = page.id

        :ok =
          WebRunTimeMetaDataState.save(%{
            id: page.id,
            site: site.name,
            path: page.path,
            title: page.name,
            created_at: DateTime.utc_now(),
            section: "Page",
            priority: 0,
            language: PageProvision.routing_language(page)
          })

        answered =
          for code <- ~w(en fa ar de),
              match?(
                {:ok, %{id: ^id}, _captured},
                WebRunTimeMetaDataState.resolve("/#{code}/#{language}-page", site.name)
              ),
              do: code

        assert PageEditions.served_languages(page, site.id) == answered,
               "#{page.path} in #{language} is offered in languages the resolver does not answer"
      end
    end
  end

  describe "indexable/1" do
    test "is the site's active pages every visitor may open", %{site: site} do
      open = create_page!(site_id: site.id, path: "/open")
      unset = create_page!(site_id: site.id, path: "/unset", permissions: nil)
      create_page!(site_id: site.id, path: "/off", active: false)
      create_page!(site_id: site.id, path: "/members", permissions: ["members:read"])
      create_page!(site_id: site.id, path: "/:lang/members", permissions: ["members:read"])
      create_page!(site_id: create_site!().id, path: "/elsewhere")

      archived = create_page!(site_id: site.id, path: "/gone")
      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      :ok =
        archived
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, actor: tenant)
        |> Ash.destroy()

      {listed, hidden} = PageEditions.indexable(site.id)

      assert Enum.map(listed, & &1.id) == [open.id, unset.id]
      # A pattern holds no one address of its own, so only the literal page is among them.
      assert hidden == MapSet.new(["/members"])
    end

    # THE ROBOTS META THE HEAD RENDERS: a page's own replaces its layout's there, so a page that says
    # `index` under a layout that says `noindex` is indexed.
    test "leaves out a page whose robots meta says noindex, its own or else its layout's", %{
      site: site
    } do
      hidden = [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, follow"}]
      layout = create_layout!(site_id: site.id, path: "/layouts/hidden", seo_tags: hidden)

      create_page!(site_id: site.id, path: "/a-own", seo_tags: hidden)

      create_page!(
        site_id: site.id,
        path: "/b-none",
        seo_tags: [%{tag: "META", attrs: %{"name" => "Robots", "content" => "NONE"}}]
      )

      create_page!(site_id: site.id, path: "/c-layout", layout_id: layout.id)

      overrides =
        create_page!(
          site_id: site.id,
          path: "/d-overrides",
          layout_id: layout.id,
          seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "index, follow"}]
        )

      described =
        create_page!(
          site_id: site.id,
          path: "/e-described",
          seo_tags: [%{tag: "meta", attrs: %{"name" => "description"}, content: "noindex"}]
        )

      {listed, hidden} = PageEditions.indexable(site.id)

      assert Enum.map(listed, & &1.id) == [overrides.id, described.id]
      assert hidden == MapSet.new(["/a-own", "/b-none", "/c-layout"])
    end
  end

  describe "listed?/2" do
    @noindex [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, follow"}]
    @index [%{"tag" => "meta", "attrs" => %{"name" => "robots", "content" => "index"}}]

    test "lists a record that names no permission and does not ask to be left out" do
      assert PageEditions.listed?(%{permissions: [], seo_tags: []})
      assert PageEditions.listed?(%{permissions: nil, seo_tags: nil})
      assert PageEditions.listed?(%{})

      refute PageEditions.listed?(%{permissions: ["members:read"], seo_tags: []})
      refute PageEditions.listed?(%{permissions: [], seo_tags: @noindex})
    end

    test "reads what the record belongs to: either's permission, its robots meta under the record's" do
      refute PageEditions.listed?(%{permissions: []}, %{permissions: ["members:read"]})
      refute PageEditions.listed?(%{seo_tags: []}, %{seo_tags: @noindex})
      assert PageEditions.listed?(%{seo_tags: @index}, %{seo_tags: @noindex})
      refute PageEditions.listed?(%{seo_tags: @noindex}, %{seo_tags: @index})
    end
  end

  describe "untranslated/1" do
    test "is the site's languages the group has no row in, inactive rows included", %{site: site} do
      master = create_page!(site_id: site.id, name: "team", path: "/team")

      create_page!(
        site_id: site.id,
        name: "team-fa",
        path: "/fa/team",
        language: "fa",
        language_group_id: master.id,
        active: false
      )

      assert PageEditions.untranslated(master) == ["ar"]
    end

    test "counts an archived edition, which a second one would keep from being restored", %{
      site: site
    } do
      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      master = create_page!(site_id: site.id, name: "crew", path: "/crew")

      ar =
        create_page!(
          site_id: site.id,
          name: "crew-ar",
          path: "/ar/crew",
          language: "ar",
          language_group_id: master.id
        )

      :ok =
        ar
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, actor: tenant)
        |> Ash.destroy()

      assert PageEditions.untranslated(master) == ["fa"]
    end
  end

  describe "translate/4" do
    setup %{site: site} do
      layout = create_layout!(site_id: site.id, path: "/layouts/team")

      master =
        create_page!(
          site_id: site.id,
          name: "team",
          path: "/team",
          section: "company",
          layout_id: layout.id
        )

      %{master: master}
    end

    test "creates an inactive edition in the group, from the page's template", %{
      site: site,
      master: master
    } do
      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      assert {:ok, %Page{} = fa} = PageEditions.translate(master, "fa", "/fa/team", tenant)

      assert %{
               name: "team-fa",
               path: "/fa/team",
               language: "fa",
               active: false,
               section: "company"
             } = fa

      assert fa.language_group_id == master.id
      assert fa.template == master.template
      assert fa.layout_id == master.layout_id
    end

    test "and for a master user, on the page's own site", %{site: site, master: master} do
      master_user = create_user_with_permissions!(["*"])

      assert {:ok, ar} = PageEditions.translate(master, "ar", "/ar/team", master_user)
      assert ar.site_id == site.id
      assert ar.language_group_id == master.id
    end
  end

  # A PART OF A PAGE IS A DIFFERENT PAGE: without its permissions a members-only translation opens to
  # everyone, without its helpers its template does not compile, without its events its clicks go
  # nowhere.
  describe "translate/4 of a page with code, permissions and SEO" do
    setup %{site: site} do
      source =
        create_page!(
          site_id: site.id,
          name: "members",
          path: "/members",
          template: ~S|<div phx-click="wave">{shout("hi")}</div>|,
          helpers: [%{name: "shout", args: "word", code: "String.upcase(word)"}],
          events: [%{name: "wave", code: "{:noreply, socket}"}],
          infos: [%{name: ":tick", code: "{:noreply, socket}"}],
          permissions: ["members:read"],
          seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex"}],
          schema: [%{"@type" => "WebPage"}],
          resource_links: [%{type: "css", href: "/members.css", rel: "stylesheet"}],
          extra: %{"theme" => "dark"},
          content: %{"hero" => "Welcome"},
          description: "For members",
          priority: 7
        )

      %{source: source}
    end

    test "is the whole page but its name, path, language, group and state", %{source: source} do
      master_user = create_user_with_permissions!(["*"])

      assert {:ok, fa} = PageEditions.translate(source, "fa", "/fa/members", master_user)

      copied =
        Page
        |> Ash.Resource.Info.action(:create)
        |> Map.fetch!(:accept)
        |> Kernel.--([:name, :path, :language, :language_group_id, :active])

      assert Map.take(fa, copied) == Map.take(source, copied)
      assert fa.permissions == ["members:read"]
      assert [%{name: "shout"}] = fa.helpers
      assert [%{name: "wave"}] = fa.events
    end

    # THE PAGE SECTION WRITES A PAGE'S CODE, so it translates one carrying code — while the
    # deployment takes author-written Elixir at all.
    test "is the page section's to make", %{site: site, source: source} do
      tenant = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert {:ok, fa} = PageEditions.translate(source, "fa", "/fa/members", tenant)
      assert [%{name: "wave"}] = fa.events
    end

    test "is refused while author-written Elixir is off", %{site: site, source: source} do
      on_exit(fn -> Application.delete_env(:mishka_cms_core, :page_code) end)
      tenant = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)
      Application.put_env(:mishka_cms_core, :page_code, :off)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               PageEditions.translate(source, "fa", "/fa/members", tenant)

      assert Enum.any?(errors, &(Map.get(&1, :field) in [:events, :infos, :helpers])),
             "the refusal does not name the field that carried the code"
    end
  end

  # THE VISUAL EDITOR'S CSS IS KEYED ON A CLASS IN THE MARKUP. `ElementCss` files an element's rule
  # under a minted `pb-xxxxxxxx` class, in a stylesheet row named after the document, and every row
  # is compiled into the one site stylesheet. A translation that kept the original's classes and not
  # its row was styled by the original's rules, a rule written on the translation restyled the
  # original, and the builder pruning that element from the original stripped the translation.
  describe "translate/4 of a page styled in the Visual Editor" do
    @styled "pb-0a1b2c3d"
    @handle "pb-99998888"
    @dead "pb-deadbeef"

    setup %{site: site} do
      actor = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)

      source =
        create_page!(
          site_id: site.id,
          name: "styled",
          path: "/styled",
          template:
            ~s(<div class="p-2 #{@styled}" data-target=".#{@handle}"><p class="#{@handle}">hi</p></div>)
        )

      {:ok, _} = ElementCss.put(actor, site.id, owner(source), @styled, "padding: 20px;")
      {:ok, _} = ElementCss.put(actor, site.id, owner(source), @handle, "color: red;")
      {:ok, rules} = ElementCss.put(actor, site.id, owner(source), @dead, "margin: 0;")

      assert {:ok, fa} = PageEditions.translate(source, "fa", "/fa/styled", actor)

      %{actor: actor, source: source, rules: rules, fa: fa, fresh: fresh_scopes(source, fa)}
    end

    # The class is a CSS key and a handle both — an interaction points at `.pb-…` — so the swap is
    # over the whole text rather than over `class` attributes.
    test "carries a class of its own, everywhere the markup names it", %{
      source: source,
      fa: fa,
      fresh: fresh
    } do
      assert Map.keys(fresh) |> Enum.sort() == Enum.sort([@styled, @handle])
      assert fresh |> Map.values() |> Enum.all?(&(&1 =~ ~r/^pb-[a-f0-9]{8}$/))
      assert MapSet.disjoint?(MapSet.new(Map.keys(fresh)), MapSet.new(Map.values(fresh)))

      assert Enum.reduce(fresh, source.template, fn {old, new}, text ->
               String.replace(text, old, new)
             end) == fa.template
    end

    # A rule whose element is no longer in the markup is one the builder prunes on the original's
    # next save; on a translation it would be a rule for nothing, filed under the original's class.
    test "holds the CSS of those elements in its own row, under its own classes", %{
      actor: actor,
      site: site,
      fa: fa,
      fresh: fresh
    } do
      assert ElementCss.all(actor, site.id, owner(fa)) == %{
               fresh[@styled] => "padding: 20px;",
               fresh[@handle] => "color: red;"
             }
    end

    test "is restyled without restyling the original", %{
      actor: actor,
      site: site,
      source: source,
      rules: rules,
      fa: fa,
      fresh: fresh
    } do
      {:ok, _} = ElementCss.put(actor, site.id, owner(fa), fresh[@styled], "padding: 99px;")

      assert ElementCss.all(actor, site.id, owner(source)) == rules

      assert Ash.get!(Page, source.id, tenant: site.id, authorize?: false).template ==
               source.template

      refute Enum.any?(
               Map.keys(ElementCss.all(actor, site.id, owner(fa))),
               &Map.has_key?(rules, &1)
             )
    end
  end

  describe "translate/4 of a page nobody styled" do
    test "writes no element CSS row for the translation", %{site: site} do
      actor = create_user_with_permissions!(["admin:dashboard:*"], site_id: site.id)
      source = create_page!(site_id: site.id, name: "plain", path: "/plain")

      assert {:ok, fa} = PageEditions.translate(source, "fa", "/fa/plain", actor)

      row = ElementCss.row_name(owner(fa))

      assert Stylesheet
             |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
             |> Ash.Query.filter(name == ^row)
             |> Ash.read!(page: [limit: 10], tenant: site.id, authorize?: false)
             |> Map.fetch!(:results) == []
    end
  end

  # The owner the builder files a page's element CSS under.
  defp owner(page), do: "page-#{page.id}"

  defp fresh_scopes(source, translation) do
    [source.template, translation.template]
    |> Enum.map(&(~r/pb-[a-f0-9]{8}/ |> Regex.scan(&1) |> List.flatten() |> Enum.uniq()))
    |> Enum.zip_with(fn [old, new] -> {old, new} end)
    |> Map.new()
  end
end
