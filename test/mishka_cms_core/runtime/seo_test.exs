defmodule MishkaCmsCore.Runtime.SeoTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.Seo`: a database page's default head, the layers that replace it, the
  variables a stored value names, a plugin's answer, and the catalog an editor reads.

  `async: false` — the settings cache is process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaCmsCore.Runtime.Seo
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  @base "https://seo.test"

  setup do
    snapshot = SettingsState.snapshot()
    host = "seo-#{System.unique_integer([:positive])}.test"
    site = create_site!(name: host, host: host, active: true)

    {:ok, _} = Settings.put("site.title", "Acme Studio", site_id: site.id)
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    on_exit(fn -> SettingsState.restore(snapshot) end)

    %{site: site}
  end

  describe "the default head" do
    test "holds every tag that has a value, and no other", %{site: site} do
      head = Seo.head(seo(site), base: @base)

      assert value(head, "link", "rel", "canonical") == "#{@base}/en/about"
      assert value(head, "meta", "name", "robots") == "index, follow, max-image-preview:large"
      assert value(head, "meta", "property", "og:type") == "website"
      assert value(head, "meta", "property", "og:title") == "About the studio"
      assert value(head, "meta", "property", "og:url") == "#{@base}/en/about"
      assert value(head, "meta", "property", "og:site_name") == "Acme Studio"
      assert value(head, "meta", "property", "og:locale") == "en_US"
      assert value(head, "meta", "name", "twitter:card") == "summary"
      assert value(head, "meta", "name", "twitter:title") == "About the studio"

      for {key, name} <- [
            {"name", "description"},
            {"property", "og:description"},
            {"property", "og:image"},
            {"property", "og:image:alt"},
            {"name", "twitter:description"},
            {"name", "twitter:image"},
            {"property", "og:locale:alternate"}
          ] do
        assert value(head, "meta", key, name) == nil, "#{name} was emitted with no value"
      end

      assert head.title == "About the studio"
      assert head.url == "#{@base}/en/about"
    end

    test "fills the description and image tags and asks for a large card", %{site: site} do
      head =
        Seo.head(seo(site, description: "What the studio does.", image: "/uploads/cover.png"),
          base: @base
        )

      image = "#{@base}/uploads/cover.png"

      assert value(head, "meta", "name", "description") == "What the studio does."
      assert value(head, "meta", "property", "og:description") == "What the studio does."
      assert value(head, "meta", "name", "twitter:description") == "What the studio does."
      assert value(head, "meta", "property", "og:image") == image
      assert value(head, "meta", "property", "og:image:alt") == "About the studio"
      assert value(head, "meta", "name", "twitter:image") == image
      assert value(head, "meta", "name", "twitter:card") == "summary_large_image"
    end

    test "keeps a page that needs a permission out of an index", %{site: site} do
      head = Seo.head(seo(site), base: @base, restricted?: true)

      assert value(head, "meta", "name", "robots") == "noindex, nofollow"
    end

    test "links each edition absolutely, the primary language as x-default", %{site: site} do
      languages = [%{language: "en", path: "/en/about"}, %{language: "fa", path: "/fa/about"}]

      head =
        Seo.head(seo(site, language: "fa", url: "/fa/about"), base: @base, languages: languages)

      assert alternates(head) == [
               {"en", "#{@base}/en/about"},
               {"fa", "#{@base}/fa/about"},
               {"x-default", "#{@base}/en/about"}
             ]

      assert value(head, "meta", "property", "og:locale") == "fa_IR"
      assert value(head, "meta", "property", "og:locale:alternate") == "en_US"
    end

    test "names no alternate for a page in one language", %{site: site} do
      assert alternates(Seo.head(seo(site), base: @base, languages: [])) == []
    end

    test "names x-default once, at the edition in the site's first language", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["fa", "en"], site_id: site.id)
      languages = [%{language: "en", path: "/en/about"}, %{language: "fa", path: "/about"}]

      head = Seo.head(seo(site), base: @base, languages: languages)

      assert Enum.filter(alternates(head), &match?({"x-default", _href}, &1)) == [
               {"x-default", "#{@base}/about"}
             ]
    end

    test "emits no relative address, and an http one as it is", %{site: site} do
      head = Seo.head(seo(site, url: "/en/about", image: "http://cdn.test/a.png"), base: nil)

      assert value(head, "link", "rel", "canonical") == nil
      assert value(head, "meta", "property", "og:image") == "http://cdn.test/a.png"
      assert value(head, "meta", "name", "twitter:card") == "summary_large_image"

      head = Seo.head(seo(site, image: "javascript:alert(1)"), base: @base)

      assert value(head, "meta", "property", "og:image") == nil
      assert value(head, "meta", "name", "twitter:card") == "summary"
    end

    test "keeps a sign-in page out of an index, unless a stored robots tag says otherwise", %{
      site: site
    } do
      restricted? = Seo.noindex?([], %{"auth_role" => "sign_in", "visitors_only" => true})
      head = Seo.head(seo(site), base: @base, restricted?: restricted?)

      assert value(head, "meta", "name", "robots") == "noindex, nofollow"

      stored = [meta("name", "robots", "index, follow")]
      head = Seo.head(seo(site), base: @base, restricted?: restricted?, layers: [[], stored])

      assert values(head, "meta", "name", "robots") == ["index, follow"]
    end

    test "keeps a record that names a permission out of an index, and hands its permissions on",
         %{
           site: site
         } do
      head = Seo.head(seo(site, permissions: ["members:read"]), base: @base)

      assert value(head, "meta", "name", "robots") == "noindex, nofollow"
      assert head.permissions == ["members:read"]

      stored = [meta("name", "robots", "index, follow")]
      head = Seo.head(seo(site, permissions: ["members:read"]), base: @base, layers: [[], stored])

      assert values(head, "meta", "name", "robots") == ["index, follow"]

      head = Seo.head(seo(site), base: @base, restricted?: false)

      assert value(head, "meta", "name", "robots") == "index, follow, max-image-preview:large"
      assert head.permissions == []
    end

    test "is one WebPage of JSON-LD, part of the site", %{site: site} do
      head =
        Seo.head(seo(site, description: "What the studio does.", image: "/uploads/cover.png"),
          base: @base
        )

      assert [json] = head.schema

      assert Jason.decode!(json) == %{
               "@context" => "https://schema.org",
               "@type" => "WebPage",
               "name" => "About the studio",
               "description" => "What the studio does.",
               "url" => "#{@base}/en/about",
               "inLanguage" => "en",
               "image" => "#{@base}/uploads/cover.png",
               "isPartOf" => %{"@type" => "WebSite", "name" => "Acme Studio", "url" => @base}
             }
    end

    # A plain-text field holds `&` as typed (`MishkaCmsCore.PlainText`); the head is where it is
    # escaped, once — rendered the way the host's `page_head` renders it.
    test "writes a title with an ampersand escaped once, in the tags and in the JSON-LD", %{
      site: site
    } do
      html = site |> seo(title: "MCP & AI-Ready") |> Seo.head(base: @base) |> rendered_head()

      assert html =~ ~s(content="MCP &amp; AI-Ready")
      refute html =~ "&amp;amp;"
      assert html =~ ~S("name":"MCP \u0026 AI-Ready")

      document = LazyHTML.from_fragment(html)

      assert document
             |> LazyHTML.query(~s(meta[property="og:title"]))
             |> LazyHTML.attribute("content") ==
               ["MCP & AI-Ready"]

      assert %{"name" => "MCP & AI-Ready"} =
               document
               |> LazyHTML.query(~s(script[type="application/ld+json"]))
               |> LazyHTML.text()
               |> Jason.decode!()
    end

    test "is replaced whole by a stored schema", %{site: site} do
      head = Seo.head(seo(site, schema: [%{"@type" => "AboutPage", "name" => "Studio"}]), [])

      assert Enum.map(head.schema, &Jason.decode!/1) == [
               %{"@type" => "AboutPage", "name" => "Studio"}
             ]
    end
  end

  describe "the layers" do
    test "a plugin's replace the defaults, the layout's a plugin's, the page's the layout's", %{
      site: site
    } do
      plugin = [meta("name", "twitter:title", "plugin"), meta("name", "author", "Ada")]
      layout = [meta("name", "description", "layout"), meta("property", "og:title", "layout")]
      page = [meta("property", "og:title", "page"), meta("name", "twitter:title", "page")]

      head =
        Seo.head(seo(site, description: "default", tags: plugin),
          base: @base,
          layers: [layout, page]
        )

      assert values(head, "meta", "name", "description") == ["layout"]
      assert values(head, "meta", "property", "og:title") == ["page"]
      assert values(head, "meta", "name", "twitter:title") == ["page"]
      assert values(head, "meta", "name", "author") == ["Ada"]
      assert value(head, "meta", "property", "og:description") == "layout"
    end

    test "a stored title is the title, the page's over the layout's, its variables filled", %{
      site: site
    } do
      layout = [%{tag: "title", attrs: %{}, content: "{{page.title}} · {{site.name}}"}]
      head = Seo.head(seo(site), base: @base, layers: [layout, []])

      assert head.title == "About the studio · Acme Studio"
      assert value(head, "meta", "property", "og:title") == "About the studio · Acme Studio"
      refute Enum.any?(head.tags, &match?({"title", _attrs}, &1))

      page = [%{tag: "title", attrs: %{}, content: "{{post.title}} | Blog"}]

      head =
        Seo.head(seo(site, title: "Post", vars: %{"post.title" => "OTP trees"}),
          base: @base,
          layers: [layout, page]
        )

      assert head.title == "OTP trees | Blog"
      assert value(head, "meta", "name", "twitter:title") == "OTP trees | Blog"
    end

    test "a plugin's tag never undoes what the page set itself", %{site: site} do
      plugin = [
        meta("property", "og:title", "Post's own"),
        meta("name", "description", "Post's own"),
        meta("name", "twitter:image", "/post.png"),
        meta("name", "author", "Ada")
      ]

      page = [
        %{tag: "title", attrs: %{}, content: "{{post.title}} - Mishka Group"},
        meta("property", "og:image", "/page.png")
      ]

      seo = seo(site, description: "Page's own.", tags: plugin, vars: %{"post.title" => "OTP"})

      head = Seo.head(seo, base: @base, layers: [[], page], page_description?: true)

      assert value(head, "meta", "property", "og:title") == "OTP - Mishka Group"
      assert value(head, "meta", "name", "description") == "Page's own."
      assert value(head, "meta", "name", "twitter:image") == "#{@base}/page.png"
      assert value(head, "meta", "name", "author") == "Ada"

      # Nothing set by the page: the plugin's tags stand.
      head = Seo.head(%{seo | description: "Plugin's."}, base: @base)

      assert value(head, "meta", "property", "og:title") == "Post's own"
      assert value(head, "meta", "name", "description") == "Post's own"
    end

    test "a stored title naming a variable that does not resolve leaves the title as it was", %{
      site: site
    } do
      page = [%{tag: "title", attrs: %{}, content: "{{post.title}} | Blog"}]
      head = Seo.head(seo(site), base: @base, layers: [[], page])

      assert head.title == "About the studio"
    end

    test "a stored og:image wins over a plugin's image", %{site: site} do
      page = [meta("property", "og:image", "{{post.cover}}")]

      head =
        Seo.head(seo(site, image: "/plugin.png", vars: %{"post.cover" => "/cover.png"}),
          base: @base,
          layers: [[], page]
        )

      assert head.image == "#{@base}/cover.png"
      assert value(head, "meta", "name", "twitter:image") == "#{@base}/cover.png"
    end

    test "the description fills its variables, and one that does not resolve gives way", %{
      site: site
    } do
      head =
        Seo.head(
          seo(site,
            description: "{{post.excerpt}} Read more.",
            vars: %{"post.excerpt" => "Trees."}
          ),
          base: @base
        )

      assert head.description == "Trees. Read more."
      assert value(head, "meta", "property", "og:description") == "Trees. Read more."

      stored = [meta("name", "description", "Stored.")]

      head =
        Seo.head(seo(site, description: "{{post.excerpt}}"), base: @base, layers: [[], stored])

      assert head.description == "Stored."
    end

    test "a stored description and og:image stand in for empty values", %{site: site} do
      page = [meta("name", "description", "Stored."), meta("property", "og:image", "/a.png")]
      head = Seo.head(seo(site), base: @base, layers: [[], page])

      assert value(head, "meta", "property", "og:description") == "Stored."
      assert value(head, "meta", "name", "twitter:image") == "#{@base}/a.png"
      assert value(head, "meta", "name", "twitter:card") == "summary_large_image"
      assert head.description == "Stored."
      assert head.image == "#{@base}/a.png"
    end

    test "og:description and twitter:description say a stored description, in any layer", %{
      site: site
    } do
      stored = [meta("name", "description", "Stored.")]

      for {where, seo, layers} <- [
            {"plugin", seo(site, description: "Plugin's.", tags: stored), []},
            {"layout", seo(site, description: "Plugin's."), [stored, []]},
            {"page", seo(site, description: "Plugin's."), [[], stored]}
          ] do
        head = Seo.head(seo, base: @base, layers: layers)

        for {key, name} <- [
              {"name", "description"},
              {"property", "og:description"},
              {"name", "twitter:description"}
            ] do
          assert values(head, "meta", key, name) == ["Stored."], "#{name} under the #{where}'s"
        end

        assert head.description == "Stored."
        assert [json] = head.schema
        assert %{"description" => "Stored."} = Jason.decode!(json)
      end
    end

    test "a stored og:description or twitter:description wins over the description meta", %{
      site: site
    } do
      plugin = [
        meta("name", "description", "Stored."),
        meta("property", "og:description", "Shared.")
      ]

      page = [meta("name", "twitter:description", "Posted.")]
      head = Seo.head(seo(site, description: "Plugin's.", tags: plugin), base: @base)

      assert value(head, "meta", "name", "description") == "Stored."
      assert value(head, "meta", "property", "og:description") == "Shared."
      assert value(head, "meta", "name", "twitter:description") == "Stored."

      head =
        Seo.head(seo(site, description: "Plugin's.", tags: plugin),
          base: @base,
          layers: [[], page]
        )

      assert value(head, "meta", "property", "og:description") == "Shared."
      assert value(head, "meta", "name", "twitter:description") == "Posted."
    end

    test "the page's own description wins over a plugin's, its tags and its description meta", %{
      site: site
    } do
      plugin = [
        meta("name", "description", "Plugin's tag."),
        meta("property", "og:description", "Plugin's tag."),
        meta("name", "twitter:description", "Plugin's tag.")
      ]

      seo = seo(site, description: "Page's own.", tags: plugin)
      head = Seo.head(seo, base: @base, page_description?: true)

      for {key, name} <- [
            {"name", "description"},
            {"property", "og:description"},
            {"name", "twitter:description"}
          ] do
        assert values(head, "meta", key, name) == ["Page's own."], name
      end

      assert head.description == "Page's own."
    end

    test "og:title and twitter:title say the title, whichever layer stores it", %{site: site} do
      stored = [%{tag: "title", attrs: %{}, content: "Stored title"}]

      for {where, seo, layers} <- [
            {"plugin", seo(site, title: "Plugin's", tags: stored), []},
            {"layout", seo(site, title: "Plugin's"), [stored, []]},
            {"page", seo(site, title: "Plugin's"), [[], stored]}
          ] do
        head = Seo.head(seo, base: @base, layers: layers)

        assert head.title == "Stored title"
        assert values(head, "meta", "property", "og:title") == ["Stored title"], where
        assert values(head, "meta", "name", "twitter:title") == ["Stored title"], where
      end

      plugin = stored ++ [meta("property", "og:title", "Shared")]
      head = Seo.head(seo(site, title: "Plugin's", tags: plugin), base: @base)

      assert head.title == "Stored title"
      assert value(head, "meta", "property", "og:title") == "Shared"
      assert value(head, "meta", "name", "twitter:title") == "Stored title"
    end

    test "a stored address that is a path is written on the base", %{site: site} do
      page = [
        %{tag: "link", attrs: %{"rel" => "canonical", "href" => "/en/elsewhere"}},
        meta("property", "og:image", "/a.png"),
        meta("name", "twitter:image", "//cdn.test/a.png"),
        %{tag: "link", attrs: %{"rel" => "preload", "href" => "/f.woff2"}}
      ]

      head = Seo.head(seo(site), base: @base, layers: [[], page])

      assert value(head, "link", "rel", "canonical") == "#{@base}/en/elsewhere"
      assert value(head, "meta", "property", "og:image") == "#{@base}/a.png"
      assert value(head, "meta", "name", "twitter:image") == "//cdn.test/a.png"
      assert value(head, "link", "rel", "preload") == "/f.woff2"
    end

    test "only a meta or a link renders, with plain attribute names", %{site: site} do
      page = [
        %{tag: "script", attrs: %{"src" => "/evil.js"}, content: "alert(1)"},
        %{"tag" => "META", "attrs" => %{"name" => "author", "onload" => "x", "a b" => "y"}},
        %{tag: "link", attrs: %{"rel" => "preload", "href" => "/f.woff2", "media" => %{}}}
      ]

      head = Seo.head(seo(site), base: @base, layers: [[], page])

      refute Enum.any?(head.tags, &match?({"script", _}, &1))
      assert {"meta", [{"name", "author"}]} in head.tags
      assert {"link", [{"href", "/f.woff2"}, {"rel", "preload"}]} in head.tags
    end
  end

  describe "variables" do
    test "fill a stored tag, the core ones and a plugin's, the plugin's winning", %{site: site} do
      page = [
        meta("property", "og:title", "{{ post.title }} · {{site.name}}"),
        meta("name", "twitter:title", "{{page.title}}"),
        %{tag: "link", attrs: %{"rel" => "author", "href" => "{{site.url}}/team"}}
      ]

      head =
        Seo.head(seo(site, vars: %{"post.title" => "Hello", "page.title" => "From the plugin"}),
          base: @base,
          layers: [[], page]
        )

      assert value(head, "meta", "property", "og:title") == "Hello · Acme Studio"
      assert value(head, "meta", "name", "twitter:title") == "From the plugin"
      assert value(head, "link", "rel", "author") == "#{@base}/team"
    end

    test "leave out a tag whose placeholder does not resolve", %{site: site} do
      page = [
        meta("property", "og:title", "{{post.title}}"),
        meta("name", "author", "{{ post.author }}"),
        meta("name", "keywords", "{{not a key}}")
      ]

      head = Seo.head(seo(site), base: @base, layers: [[], page])

      assert value(head, "meta", "property", "og:title") == "About the studio"
      assert value(head, "meta", "name", "author") == nil
      assert value(head, "meta", "name", "keywords") == nil
      refute Enum.any?(head.tags, fn {_tag, attrs} -> inspect(attrs) =~ "{{" end)
    end

    test "fill the schema, removing each value that does not resolve", %{site: site} do
      schema = [
        %{
          "@type" => "Article",
          "headline" => "{{post.title}}",
          "url" => "{{page.url}}",
          "author" => %{"@type" => "Person", "name" => "{{post.author}}"},
          "keywords" => ["{{post.tag}}", "elixir"]
        }
      ]

      head =
        Seo.head(seo(site, schema: schema, vars: %{"post.title" => "Hello", post: "unused"}),
          base: @base
        )

      assert [json] = head.schema
      refute json =~ "{{"

      assert Jason.decode!(json) == %{
               "@type" => "Article",
               "headline" => "Hello",
               "url" => "#{@base}/en/about",
               "author" => %{"@type" => "Person"},
               "keywords" => ["elixir"]
             }
    end

    test "page.image and page.description read a stored og:image and description", %{site: site} do
      page = [meta("name", "description", "Stored."), meta("property", "og:image", "/a.png")]

      schema = [
        %{
          "@type" => "Article",
          "image" => "{{page.image}}",
          "description" => "{{page.description}}"
        }
      ]

      head = Seo.head(seo(site, schema: schema), base: @base, layers: [[], page])

      assert [json] = head.schema

      assert Jason.decode!(json) == %{
               "@type" => "Article",
               "image" => "#{@base}/a.png",
               "description" => "Stored."
             }
    end

    test "a schema left empty by them falls back to the WebPage", %{site: site} do
      head = Seo.head(seo(site, schema: [%{"name" => "{{post.title}}"}]), base: @base)

      assert [json] = head.schema
      assert %{"@type" => "WebPage"} = Jason.decode!(json)
    end

    test "are listed for an editor, every core one filled", %{site: site} do
      keys = Enum.map(Seo.variables(), & &1.key)
      page = for key <- keys, do: meta("name", "x-" <> key, "{{#{key}}}")

      head =
        Seo.head(seo(site, description: "D", image: "/a.png"), base: @base, layers: [[], page])

      for key <- keys do
        assert is_binary(value(head, "meta", "name", "x-" <> key)), "{{#{key}}} did not resolve"
      end

      assert Enum.all?(Seo.variables(), &(is_binary(&1.label) and is_binary(&1.help)))
    end
  end

  describe "a plugin's question" do
    test "starts from the page's own values", %{site: site} do
      page = %{
        title: "About",
        language: "fa",
        path: "/fa/about",
        seo: %{description: "D", schema: [%{"@type" => "AboutPage"}], meta_tags: []}
      }

      site_id = site.id
      url = "#{@base}/fa/about"

      assert %{
               title: "About",
               description: "D",
               image: nil,
               type: "website",
               url: ^url,
               language: "fa",
               tags: [],
               schema: [%{"@type" => "AboutPage"}],
               vars: %{},
               var_docs: [],
               page: ^page,
               site_id: ^site_id,
               params: %{}
             } = Seo.given(page, site_id: site_id, url: url)
    end
  end

  describe "a plugin's answer" do
    test "keeps what has the right type and the given value otherwise" do
      given = %{
        title: "Page",
        description: "D",
        image: nil,
        type: "website",
        url: "#{@base}/a",
        language: "en",
        tags: [],
        schema: [],
        vars: %{},
        var_docs: [],
        page: %{title: "Page"},
        site_id: "site",
        params: %{"slug" => "a"}
      }

      returned = %{
        given
        | title: "Post",
          description: nil,
          image: 42,
          type: "",
          tags: :none,
          vars: %{"post.title" => "Post"},
          var_docs: [%{key: "post.title", label: "Post title"}],
          page: :changed,
          site_id: "other",
          params: %{}
      }

      assert Seo.accept(returned, given) == %{
               given
               | title: "Post",
                 vars: %{"post.title" => "Post"},
                 var_docs: [%{key: "post.title", label: "Post title"}]
             }

      assert Seo.accept(:not_a_map, given) == given
    end

    test "fills the description and the schema only where the page left them empty" do
      given = %{
        title: "Page",
        description: nil,
        image: nil,
        type: "website",
        url: "#{@base}/a",
        language: "en",
        tags: [],
        schema: [],
        vars: %{},
        var_docs: [],
        page: %{title: "Page"},
        site_id: "site",
        params: %{"slug" => "a"}
      }

      returned = %{
        given
        | description: "The post.",
          schema: [%{"@type" => "BlogPosting"}]
      }

      assert %{description: "The post.", schema: [%{"@type" => "BlogPosting"}]} =
               Seo.accept(returned, given)

      own = %{given | description: "{{post.excerpt}}", schema: [%{"@type" => "Article"}]}

      assert %{description: "{{post.excerpt}}", schema: [%{"@type" => "Article"}]} =
               Seo.accept(returned, own)

      assert %{description: "The post."} = Seo.accept(returned, %{given | description: "  "})
    end

    test "keeps the record's permission names, and nothing else in them" do
      given = Seo.given(%{title: "Page", language: "en"}, site_id: "site")

      assert given.permissions == []

      assert %{permissions: ["members:read"]} =
               Seo.accept(%{given | permissions: ["members:read", 7, nil]}, given)

      assert %{permissions: []} = Seo.accept(%{given | permissions: "members:read"}, given)
    end
  end

  test "absolute/2 takes an http(s) address or a path on the base" do
    assert Seo.absolute("https://cdn.test/a.png", @base) == "https://cdn.test/a.png"
    assert Seo.absolute("http://cdn.test/a.png", @base) == "http://cdn.test/a.png"
    assert Seo.absolute("/a.png", @base) == "#{@base}/a.png"
    assert Seo.absolute("/a.png", nil) == nil
    assert Seo.absolute("//cdn.test/a.png", @base) == nil
    assert Seo.absolute("javascript:alert(1)", @base) == nil
    assert Seo.absolute("a.png", @base) == nil
  end

  # The sitemap and robots.txt name a site on the same address.
  test "base/1 is the site's address as the sitemap writes it" do
    assert Seo.base("blog.test") == MishkaCmsCore.Helpers.site_url("blog.test", "")
    assert Seo.base("blog.test") =~ ~r{\Ahttps?://blog\.test(:\d+)?\z}
    assert Seo.base(nil) == nil
    assert Seo.base("") == nil
  end

  test "noindex?/2 is true for a page that needs a permission or is a sign-in page" do
    assert Seo.noindex?(["members:read"], %{})
    assert Seo.noindex?([], %{"visitors_only" => true})
    assert Seo.noindex?([], %{auth_role: "sign_out"})
    assert Seo.noindex?(:unreadable, nil)
    refute Seo.noindex?([], %{"auth_role" => ""})
    refute Seo.noindex?(nil, %{"visitors_only" => false})
    refute Seo.noindex?([], nil)
  end

  test "locale/1 writes the region the code names, else the one CLDR gives its language" do
    assert Seo.locale("pt-br") == "pt_BR"
    assert Seo.locale("zh-hant-tw") == "zh_TW"
    assert Seo.locale("EN_gb") == "en_GB"
    assert Seo.locale("en") == "en_US"
    assert Seo.locale("fa") == "fa_IR"
    assert Seo.locale("de") == "de_DE"
    assert Seo.locale("ar") == "ar_EG"
    assert Seo.locale("zh-hant") == "zh_TW"
    # A numeric region (Latin America) is no Open Graph territory.
    assert Seo.locale("es-419") == "es"
    assert Seo.locale(nil) == nil
    assert Seo.locale("not a code") == nil
  end

  test "locale/1 gives every language the CMS offers its language and a region CLDR names" do
    for language <- MishkaCmsCore.Runtime.Languages.known(),
        do: assert(Seo.locale(language) =~ ~r/\A#{language}(_[A-Z]{2})?\z/, language)
  end

  defmodule RaisingSeo do
    @moduledoc false
    def call(_seo), do: raise("broken extension")
  end

  describe "resolve/2" do
    test "a page that shows a record no plugin answered for — one raised — opens only for *",
         %{site: site} do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: RaisingSeo,
          event: Seo.event(),
          extension: :mishka_cms_core,
          status: :started
        })

      :ok = MishkaInstaller.Event.EventHandler.do_compile(Seo.event(), :start, false)

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(:name, RaisingSeo, false)
        MishkaInstaller.Event.EventHandler.do_compile(Seo.event(), :start, false)
      end)

      page = %{title: "Post", language: "en", seo: %{description: nil, schema: []}}
      opts = [site_id: site.id, base: @base]

      ExUnit.CaptureLog.capture_log(fn ->
        assert Seo.resolve(page, opts ++ [url: "/en/blog/x", record: "blog:post"]).permissions ==
                 ["*"]

        assert Seo.resolve(page, opts ++ [url: "/en/about"]).permissions == []
      end)
    end

    test "while its plugins cannot run, a page that shows a record opens only for whoever holds *",
         %{site: site} do
      MishkaCmsCore.Test.EventCannotRun.stub!(Seo.event())
      page = %{title: "Post", language: "en", seo: %{description: nil, schema: []}}
      opts = [site_id: site.id, base: @base]

      assert Seo.resolve(page, opts ++ [url: "/en/blog/x", record: "blog:post"]).permissions ==
               ["*"]

      assert Seo.resolve(page, opts ++ [url: "/en/about"]).permissions == []
    end

    test "is the head a plugin's answer builds, with its variables listed", %{site: site} do
      page = %{title: "About", language: "en", seo: %{description: "D", schema: []}}

      head =
        Seo.resolve(page,
          site_id: site.id,
          url: "/en/about",
          base: @base,
          layers: [[], [meta("property", "og:title", "{{page.title}} · {{site.name}}")]]
        )

      assert head.title == "About"
      assert head.url == "#{@base}/en/about"
      assert head.var_docs == []
      assert value(head, "meta", "property", "og:title") == "About · Acme Studio"
      assert value(head, "meta", "name", "description") == "D"
    end
  end

  describe "resolve/2 for an editor's preview" do
    defmodule DocsOnly do
      @moduledoc false
      use MishkaInstaller.Event.Hook, event: "runtime:page:seo"

      @impl true
      def call(%{page: %{path: "/:lang/stand-ins/:slug"}} = seo),
        do: {:reply, %{seo | var_docs: [%{key: "post.title", label: "Post title"}]}}

      def call(seo), do: {:reply, seo}
    end

    setup do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: DocsOnly,
          event: "runtime:page:seo",
          extension: :mishka_installer,
          status: :started
        })

      :ok = MishkaInstaller.Event.EventHandler.do_compile("runtime:page:seo", :start, false)

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(:name, DocsOnly, false)
        MishkaInstaller.Event.EventHandler.do_compile("runtime:page:seo", :start, false)
      end)
    end

    test "shows where a plugin's variable goes when there is no record to fill it", %{
      site: site
    } do
      page = %{
        title: "Blog post",
        path: "/:lang/stand-ins/:slug",
        language: "en",
        seo: %{description: "{{post.title}} in short.", schema: []}
      }

      title = [%{tag: "title", attrs: %{}, content: "{{post.title}} - Mishka Group"}]
      opts = [site_id: site.id, url: "/en/stand-ins/x", base: @base, layers: [[], title]]

      preview = Seo.resolve(page, opts ++ [stand_ins: true])
      assert preview.title == "{post.title} - Mishka Group"
      assert preview.description == "{post.title} in short."

      # A visitor's head never shows one: the placeholder does not resolve, and the title is the page's.
      head = Seo.resolve(page, opts)
      assert head.title == "Blog post"
      assert head.description == nil
    end
  end

  describe "schema types" do
    test "each names its fields with a label and a default" do
      for type <- Seo.schema_types() do
        assert is_binary(type.type) and is_binary(type.label)

        for field <- type.fields do
          assert is_binary(field.key) and is_binary(field.label) and is_binary(field.default)

          case String.split(field.key, ".") do
            [_plain] -> :ok
            [parent, _child] -> assert Map.has_key?(type.nested, parent), field.key
          end
        end
      end

      assert Enum.find(Seo.schema_types(), &(&1.type == "FAQPage")).faq?
    end

    test "write a JSON-LD object and read it back" do
      values = %{"headline" => "{{page.title}}", "image" => "", "author.name" => "Ada"}

      object = Seo.schema_object("Article", values)

      assert object == %{
               "@context" => "https://schema.org",
               "@type" => "Article",
               "headline" => "{{page.title}}",
               "author" => %{"@type" => "Person", "name" => "Ada"}
             }

      assert {"Article", read} = Seo.schema_values(object)
      assert read["headline"] == "{{page.title}}"
      assert read["author.name"] == "Ada"
      assert read["image"] == ""
    end

    test "write questions and answers, leaving out a pair with no question" do
      questions = [
        %{"question" => "Open on Sunday?", "answer" => "No."},
        %{"question" => " ", "answer" => "Dropped."}
      ]

      object = Seo.schema_object("FAQPage", %{"questions" => questions})

      assert object["mainEntity"] == [
               %{
                 "@type" => "Question",
                 "name" => "Open on Sunday?",
                 "acceptedAnswer" => %{"@type" => "Answer", "text" => "No."}
               }
             ]

      assert Seo.schema_values(object) ==
               {"FAQPage",
                %{"questions" => [%{"question" => "Open on Sunday?", "answer" => "No."}]}}
    end

    test "write over a stored object, keeping its other keys and removing a blank field" do
      stored = %{
        "@context" => "https://schema.org",
        "@type" => "Article",
        "headline" => "Old",
        "dateModified" => "2026-09-30",
        "author" => %{"@type" => "Person", "name" => "Ada", "url" => "/ada"}
      }

      assert Seo.schema_object("Article", %{"headline" => "New", "author.name" => ""}, stored) ==
               %{
                 "@context" => "https://schema.org",
                 "@type" => "Article",
                 "headline" => "New",
                 "dateModified" => "2026-09-30",
                 "author" => %{"@type" => "Person", "url" => "/ada"}
               }

      refute Map.has_key?(
               Seo.schema_object("Article", %{"author.name" => ""}, %{
                 "author" => %{"@type" => "Person", "name" => "Ada"}
               }),
               "author"
             )
    end

    test "write a rating as an AggregateRating, on the types search engines may star" do
      assert %{
               "@type" => "Product",
               "aggregateRating" => %{
                 "@type" => "AggregateRating",
                 "ratingValue" => "{{post.rating}}",
                 "ratingCount" => "12"
               }
             } =
               Seo.schema_object("Product", %{
                 "name" => "Kit",
                 "aggregateRating.ratingValue" => "{{post.rating}}",
                 "aggregateRating.ratingCount" => "12"
               })

      starred = for type <- Seo.schema_types(), type.stars?, do: type.type
      assert "Recipe" in starred and "Product" in starred
      refute "BlogPosting" in starred or "Article" in starred
    end

    test "know nothing of another type" do
      assert Seo.schema_object("Movie", %{}) == nil
      assert Seo.schema_values(%{"@type" => "BreadcrumbList"}) == nil
      assert Seo.schema_values(%{"name" => "untyped"}) == nil
    end
  end

  describe "stored tags" do
    test "read in one shape, whichever keys they were stored with" do
      assert Seo.stored_tags([
               %{"tag" => "meta", "attrs" => %{name: "author"}, "content" => "Ada"},
               %{tag: "link", attrs: %{"rel" => "canonical", "href" => "/a"}},
               :not_a_tag
             ]) == [
               %{tag: "meta", attrs: %{"name" => "author"}, content: "Ada"},
               %{tag: "link", attrs: %{"rel" => "canonical", "href" => "/a"}, content: nil}
             ]
    end

    test "are written, found and removed by their catalog entry" do
      tags = [meta("name", "author", "Ada")]

      tags = Seo.put_tag(tags, Seo.stored_tag("meta", %{"property" => "og:image"}, "/a.png"))
      tags = Seo.put_tag(tags, Seo.stored_tag("link", %{"rel" => "canonical"}, "/en/a"))

      assert Seo.tag_value(tags, "og:image") == "/a.png"
      assert Seo.tag_value(tags, "canonical") == "/en/a"
      assert Seo.entry_of(List.last(tags)).id == "canonical"
      assert Seo.entry_of(hd(tags)).id == "author"
      assert Seo.stored_value(List.last(tags)) == "/en/a"

      # The same identity is written in place; a repeatable entry is added beside it.
      tags = Seo.put_tag(tags, Seo.stored_tag("meta", %{"property" => "og:image"}, "/b.png"))
      assert Enum.count(tags) == 3
      assert Seo.tag_value(tags, "og:image") == "/b.png"

      tag = Seo.stored_tag("meta", %{"property" => "article:tag"}, "elixir")
      assert tags |> Seo.put_tag(tag) |> Seo.put_tag(tag) |> Enum.count() == 5

      assert tags |> Seo.drop_tag("og:image") |> Seo.tag_value("og:image") == nil
      assert Seo.tag_value(tags, "robots") == nil
      assert Seo.entry_of(meta("name", "x-custom", "1")) == nil
    end
  end

  describe "the catalog" do
    test "names every tag the default head emits, each marked default", %{site: site} do
      languages = [%{language: "en", path: "/en/about"}, %{language: "fa", path: "/fa/about"}]

      head =
        Seo.head(seo(site, description: "D", image: "/a.png"),
          base: @base,
          languages: languages
        )

      defaults = for entry <- Seo.catalog(), entry.default?, into: MapSet.new(), do: entry.id

      for {_tag, attrs} <- head.tags do
        id =
          Enum.find_value(attrs, fn {key, value} -> key in ~w(name property rel) && value end)

        assert id in defaults, "#{id} is emitted by default but not in the catalog as one"
      end
    end

    test "gives each entry its identity, words and allowed values" do
      catalog = Seo.catalog()
      by_id = Map.new(catalog, &{&1.id, &1})

      assert length(catalog) == map_size(by_id)

      for entry <- catalog do
        assert entry.tag in ["meta", "link", "title"]
        assert entry.value == if(entry.tag == "link", do: "href", else: "content")
        assert is_binary(entry.label) and is_binary(entry.help)
      end

      assert "max-image-preview:large" in by_id["robots"].values
      assert by_id["robots"].multiple?
      assert "article" in by_id["og:type"].values
      assert by_id["twitter:card"].values == ["summary", "summary_large_image"]
      assert by_id["alternate"].needs == ["hreflang"]
      refute by_id["author"].default?
      assert by_id["og:title"].default == "{{page.title}}"

      assert by_id["robots"].default
             |> String.split(", ")
             |> Enum.all?(&(&1 in by_id["robots"].values))

      assert by_id["article:tag"].repeatable?
      refute by_id["og:title"].repeatable?

      for entry <- catalog, entry.values != [] and not entry.multiple? do
        assert entry.default in entry.values, "#{entry.id} defaults to a value it does not allow"
      end
    end
  end

  defp seo(site, overrides \\ []) do
    Map.merge(
      %{
        title: "About the studio",
        description: nil,
        image: nil,
        type: "website",
        url: "#{@base}/en/about",
        language: "en",
        tags: [],
        schema: [],
        vars: %{},
        site_id: site.id
      },
      Map.new(overrides)
    )
  end

  defp meta(key, name, content), do: %{tag: "meta", attrs: %{key => name}, content: content}

  defp rendered_head(head) do
    assigns = %{seo: head}

    rendered_to_string(~H"""
    <meta :for={{"meta", attrs} <- @seo.tags} {attrs} />
    <script :for={json <- @seo.schema} type="application/ld+json">
      <%= Phoenix.HTML.raw(json) %>
    </script>
    """)
  end

  defp values(head, tag, key, name) do
    for {^tag, attrs} <- head.tags,
        {key, name} in attrs,
        do: attrs |> List.keyfind(if(tag == "meta", do: "content", else: "href"), 0) |> elem(1)
  end

  defp value(head, tag, key, name), do: head |> values(tag, key, name) |> List.first()

  defp alternates(head) do
    for {"link", attrs} <- head.tags,
        {"rel", "alternate"} in attrs,
        do: {hd(for({"hreflang", lang} <- attrs, do: lang)), hd(for({"href", h} <- attrs, do: h))}
  end

  describe "alternate_links/3" do
    test "links each edition and x-default at the primary one, as stored tags", %{site: site} do
      editions = [%{language: "en", path: "/about"}, %{language: "fa", path: "/fa/about"}]

      assert Seo.alternate_links(editions, @base, site.id) == [
               %{
                 tag: "link",
                 attrs: %{"rel" => "alternate", "hreflang" => "en", "href" => "#{@base}/about"}
               },
               %{
                 tag: "link",
                 attrs: %{"rel" => "alternate", "hreflang" => "fa", "href" => "#{@base}/fa/about"}
               },
               %{
                 tag: "link",
                 attrs: %{
                   "rel" => "alternate",
                   "hreflang" => "x-default",
                   "href" => "#{@base}/about"
                 }
               }
             ]
    end

    test "names no x-default when no edition is in the primary language", %{site: site} do
      editions = [%{language: "fa", path: "/fa/about"}, %{language: "ar", path: "/ar/about"}]

      refute Enum.any?(
               Seo.alternate_links(editions, @base, site.id),
               &(&1.attrs["hreflang"] == "x-default")
             )
    end

    test "is nothing for fewer than two editions", %{site: site} do
      assert Seo.alternate_links([%{language: "en", path: "/about"}], @base, site.id) == []
      assert Seo.alternate_links([], @base, site.id) == []
    end
  end
end
