# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.SiteLayoutTest do
  @moduledoc """
  `MishkaCmsCore.Runtime.SiteLayout`: what a page hands the `site-main` layout — the languages it is
  written in and the bar under the header — through the `runtime:page:frame` event, how the bar is
  drawn, and how an extension's pages are hung on the layout.

  What the header draws from `@page_languages` is `MishkaCmsCore.Install.StarterContentTest`'s; a
  visitor's page, through `MishkaCmsWeb.RuntimeLive`, is the host's `StarterHomePageTest`.

  `async: false` — the event registry, `SiteState` and the settings cache are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.{Languages, Layout, Page, PageProvision, SiteLayout, Translations}
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SettingsState, SiteState}
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.EventCannotRun

  require Ash.Query

  setup do
    snapshot = SettingsState.snapshot()
    name = "frame-#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)
    {:ok, _} = Settings.put("site.languages", ["en", "ar", "fa"], site_id: site.id)

    on_exit(fn -> SettingsState.restore(snapshot) end)

    %{site: site}
  end

  # A PLUGIN AS AN EXTENSION WRITES ONE: it answers for the kinds of record it owns and its own
  # section, and hands every other page back untouched.
  defmodule CategoryFrame do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:page:frame"

    # "News" in English, "الأخبار" in Arabic and "اخبار" in Persian: one row per language, each at
    # an address of its own.
    @news [
      %{language: "en", slug: "news", name: "News"},
      %{language: "ar", slug: "akhbar", name: "الأخبار"},
      %{language: "fa", slug: "akhbar-fa", name: "اخبار"}
    ]

    @impl true
    def call(%{record: "probe:category"} = frame) do
      translations =
        for row <- @news do
          %{language: row.language, path: path(row), title: row.name}
        end

      {:reply, :halt, %{frame | translations: translations}}
    end

    # AN ENGLISH POST WITH AN ARABIC TRANSLATION AND NO PERSIAN ONE.
    def call(%{record: "probe:post"} = frame) do
      {:reply, :halt,
       %{
         frame
         | translations: [
             %{language: "en", path: "/probe/post/hello"},
             %{language: "ar", path: "/ar/probe/post/marhaba"}
           ]
       }}
    end

    # A POST THAT EXISTS IN ONE LANGUAGE ONLY.
    def call(%{record: "probe:alone"} = frame),
      do: {:reply, :halt, %{frame | translations: [%{language: "en", path: "/probe/post/alone"}]}}

    # A LANGUAGE THE SITE DOES NOT PUBLISH IN, beside two it does.
    def call(%{record: "probe:german"} = frame) do
      {:reply, :halt,
       %{
         frame
         | translations: [
             %{language: "en", path: "/probe/x"},
             %{language: "de", path: "/de/probe/x"},
             %{language: "fa", path: "/fa/probe/x"}
           ]
       }}
    end

    def call(%{section: "probe"} = frame) do
      {:reply,
       %{
         frame
         | section_bar: %{
             title: "Probe",
             title_path: "/probe",
             links: [
               %{label: "Posts", path: "/probe", current: frame.page.path == "/:lang/probe"},
               %{label: "Tags", path: "/probe/tags"}
             ]
           }
       }}
    end

    def call(frame), do: {:reply, frame}

    defp path(%{language: "en", slug: slug}), do: "/probe/category/#{slug}"
    defp path(%{language: language, slug: slug}), do: "/#{language}/probe/category/#{slug}"
  end

  defmodule RaisingFrame do
    @moduledoc false
    def call(_frame), do: raise("broken extension")
  end

  # A FUNCTION COMPONENT AN EXTENSION SHIPS, the way the docs' version picker is one.
  defmodule Picker do
    @moduledoc false
    use Phoenix.Component

    attr :id, :string, required: true
    attr :versions, :list, default: []
    attr :current, :string, default: nil

    def version_select(assigns) do
      ~H"""
      <button id={@id} type="button" phx-click="probe-pick" data-current={@current}>
        <span :for={version <- @versions} data-role="probe-version">{version}</span>
      </button>
      """
    end
  end

  defp plugin!(module) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: SiteLayout.event(),
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(SiteLayout.event(), :start, false)

    on_exit(fn ->
      MishkaInstaller.Event.Event.unregister(:name, module, false)
      MishkaInstaller.Event.EventHandler.do_compile(SiteLayout.event(), :start, false)
    end)
  end

  # The page as `RuntimeLive` hands it: the `:page` section of its module, in this response's
  # language.
  defp page(path, opts \\ []) do
    %{
      title: "Probe",
      path: path,
      section: Keyword.get(opts, :section, "starter"),
      language: Keyword.get(opts, :language, "en")
    }
  end

  # WHAT A PAGE OF THE CMS'S OWN IS OFFERED IN: the same path in each language it answers in.
  @editions [
    %{language: "fa", path: "/fa/about"},
    %{language: "en", path: "/about"},
    %{language: "ar", path: "/ar/about"}
  ]

  describe "the translations a page of the CMS's own hands the layout" do
    test "are its editions, named and in the order the site lists its languages", %{site: site} do
      frame = SiteLayout.frame(page("/:lang/about"), site_id: site.id, translations: @editions)

      assert frame.translations == [
               %{language: "en", path: "/about", name: Languages.name("en"), title: nil},
               %{language: "ar", path: "/ar/about", name: Languages.name("ar"), title: nil},
               %{language: "fa", path: "/fa/about", name: Languages.name("fa"), title: nil}
             ]

      assert frame.section_bar == nil
    end

    test "are none for a page in one language, so the header draws no switcher", %{site: site} do
      one = [%{language: "en", path: "/about"}]

      assert SiteLayout.frame(page("/about"), site_id: site.id, translations: one).translations ==
               []

      assert SiteLayout.frame(page("/about"), site_id: site.id, translations: []).translations ==
               []
    end

    test "keep a name a page gives, and drop what has no language or no address", %{site: site} do
      entries = [
        %{"language" => "en", "path" => "/about", "name" => "EN"},
        %{language: "fa", path: "//elsewhere.test/fa"},
        %{language: "ar"},
        %{path: "/de/about"},
        %{language: "ar", path: "https://ar.example.test/about"},
        "not a map"
      ]

      assert SiteLayout.translations(entries, site.id) == [
               %{language: "en", path: "/about", name: "EN", title: nil},
               %{
                 language: "ar",
                 path: "https://ar.example.test/about",
                 name: Languages.name("ar"),
                 title: nil
               }
             ]
    end
  end

  describe "the translations an extension hands the layout for a record" do
    setup do: plugin!(CategoryFrame)

    test "are the record's own editions, each at its own address", %{site: site} do
      frame =
        SiteLayout.frame(page("/:lang/probe/category/:slug", section: "probe"),
          site_id: site.id,
          extra: %{"record" => "probe:category"},
          params: %{"lang" => "en", "slug" => "news"},
          translations: @editions
        )

      assert Enum.map(frame.translations, &{&1.language, &1.path, &1.title}) == [
               {"en", "/probe/category/news", "News"},
               {"ar", "/ar/probe/category/akhbar", "الأخبار"},
               {"fa", "/fa/probe/category/akhbar-fa", "اخبار"}
             ]

      # THE ARABIC ENTRY OPENS THE ARABIC CATEGORY, not the English slug under `/ar`.
      assert %{path: "/ar/probe/category/akhbar"} =
               Enum.find(frame.translations, &(&1.language == "ar"))
    end

    test "leave out a language the record is not written in", %{site: site} do
      frame =
        SiteLayout.frame(page("/:lang/probe/post/:slug"),
          site_id: site.id,
          extra: %{"record" => "probe:post"},
          translations: @editions
        )

      assert Enum.map(frame.translations, & &1.language) == ["en", "ar"]
      refute Enum.any?(frame.translations, &(&1.language == "fa"))
    end

    test "are none for a record in one language", %{site: site} do
      frame =
        SiteLayout.frame(page("/:lang/probe/post/:slug"),
          site_id: site.id,
          extra: %{"record" => "probe:alone"},
          translations: @editions
        )

      assert frame.translations == []
    end

    test "drop a language the site does not publish in", %{site: site} do
      frame =
        SiteLayout.frame(page("/:lang/probe/x"),
          site_id: site.id,
          extra: %{"record" => "probe:german"}
        )

      assert Enum.map(frame.translations, & &1.language) == ["en", "fa"]
    end

    test "leave every other page with its own editions", %{site: site} do
      frame = SiteLayout.frame(page("/:lang/about"), site_id: site.id, translations: @editions)

      assert Enum.map(frame.translations, & &1.path) == ["/about", "/ar/about", "/fa/about"]
      assert frame.section_bar == nil
    end
  end

  describe "a plugin that cannot answer" do
    test "leaves the page with what it was given when it raises", %{site: site} do
      {:ok, _} =
        MishkaInstaller.Event.Event.write(%{
          name: RaisingFrame,
          event: SiteLayout.event(),
          extension: :mishka_cms_core,
          status: :started
        })

      :ok = MishkaInstaller.Event.EventHandler.do_compile(SiteLayout.event(), :start, false)

      on_exit(fn ->
        MishkaInstaller.Event.Event.unregister(:name, RaisingFrame, false)
        MishkaInstaller.Event.EventHandler.do_compile(SiteLayout.event(), :start, false)
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        frame = SiteLayout.frame(page("/:lang/about"), site_id: site.id, translations: @editions)

        assert length(frame.translations) == 3
        assert frame.section_bar == nil
      end)
    end

    test "leaves the page with what it was given while the event cannot run", %{site: site} do
      EventCannotRun.stub!(SiteLayout.event())

      frame = SiteLayout.frame(page("/:lang/about"), site_id: site.id, translations: @editions)

      assert length(frame.translations) == 3
      assert frame.section_bar == nil
    end

    test "is read as nothing when it answers with what is not a map" do
      given = SiteLayout.given(page("/x"), translations: [])

      assert SiteLayout.accept(:nonsense, given) == %{translations: [], section_bar: nil}
      assert SiteLayout.accept(%{section_bar: "a bar"}, given).section_bar == nil
      assert SiteLayout.accept(%{translations: :none}, given).translations == []
    end
  end

  describe "the map a plugin is handed" do
    test "names the page, its section, its record, its captures and its language", %{site: site} do
      given =
        SiteLayout.given(page("/:lang/probe/post/:slug", section: "probe", language: "fa"),
          site_id: site.id,
          extra: %{"record" => "probe:post"},
          params: %{"slug" => "hello"},
          translations: @editions
        )

      assert given.section == "probe"
      assert given.record == "probe:post"
      assert given.params == %{"slug" => "hello"}
      assert given.language == "fa"
      assert given.site_id == site.id
      assert given.page.path == "/:lang/probe/post/:slug"
      assert length(given.translations) == 3
      assert given.section_bar == nil
      assert given.current_user == nil
    end

    test "names the signed-in visitor, so a plugin reads as them" do
      visitor = %{id: "visitor"}

      assert SiteLayout.given(page("/x"), current_user: visitor).current_user == visitor
    end
  end

  describe "the section bar" do
    setup do: plugin!(CategoryFrame)

    test "is an extension's, for the pages of its section", %{site: site} do
      frame = SiteLayout.frame(page("/:lang/probe", section: "probe"), site_id: site.id)

      assert %{title: "Probe", title_path: "/probe"} = frame.section_bar

      assert frame.section_bar.links == [
               %{label: "Posts", path: "/probe", current: true},
               %{label: "Tags", path: "/probe/tags", current: false}
             ]
    end

    test "is none for a page no plugin answers for", %{site: site} do
      assert SiteLayout.frame(page("/:lang/about"), site_id: site.id).section_bar == nil
    end

    test "draws nothing when there is none" do
      assert bar(nil) == ""
      assert bar(%{}) == ""
      assert bar(%{links: [%{label: "No address"}], component: "  "}) == ""
    end

    test "draws the section's name and its places, the current one marked" do
      html =
        bar(%{
          title: "Blog",
          title_path: "/blog",
          links: [
            %{label: "Posts", path: "/blog", current: true},
            %{label: "Categories", path: "/blog/categories"},
            %{label: "Tags", path: "/blog/tags"},
            %{label: "People", path: "/blog/people"},
            %{label: "Elsewhere", path: "https://example.test"}
          ]
        })

      assert html =~ ~s(id="site-section-bar")
      assert [title] = Regex.run(~r/<a [^>]*href="\/blog"[^>]*>\s*Blog\s*<\/a>/, html)
      assert title =~ "font-newsreader"

      assert [
               {"Posts", "/blog"},
               {"Categories", "/blog/categories"},
               {"Tags", "/blog/tags"},
               {"People", "/blog/people"},
               {"Elsewhere", "https://example.test"}
             ] ==
               links(html, ~s([data-role="site-section-links"] a))

      assert [current] = Regex.scan(~r/<a [^>]*aria-current="page"[^>]*>\s*Posts/, html)
      assert hd(current) =~ "bg-chip-wash"
      assert length(Regex.scan(~r/aria-current/, html)) == 1

      # A PAGE OF THE SITE IS A LIVE NAVIGATION; AN ADDRESS OFF IT IS NOT.
      assert html =~ ~r/<a [^>]*href="\/blog\/tags"[^>]*data-phx-link="redirect"/
      refute html =~ ~r/<a [^>]*href="https:\/\/example.test"[^>]*data-phx-link/
    end

    test "draws a breadcrumb, the page the reader is on last" do
      html =
        bar(%{
          crumbs: [
            %{label: "Docs", path: "/docs"},
            %{label: "Mishka CMS", path: "/docs/mishka-cms"},
            %{label: "Installation"}
          ]
        })

      assert html =~ ~s(aria-label="Breadcrumb")

      assert [{"Docs", "/docs"}, {"Mishka CMS", "/docs/mishka-cms"}] ==
               links(html, ~s([data-role="site-section-crumbs"] a))

      assert html =~ ~r/<span[^>]*aria-current="page"[^>]*>\s*Installation\s*<\/span>/
    end

    test "draws an extension's function component, with what the bar hands it" do
      html =
        bar(%{
          crumbs: [%{label: "Docs", path: "/docs"}, %{label: "Mishka CMS"}],
          component: {Picker, :version_select},
          assigns: %{id: "doc-version", versions: ["0.0.6", "0.0.5"], current: "0.0.6"}
        })

      assert [section] =
               html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query(~s([data-role="site-section-component"] #doc-version))
               |> Enum.to_list()

      assert LazyHTML.attribute(section, "data-current") == ["0.0.6"]
      assert LazyHTML.attribute(section, "phx-click") == ["probe-pick"]
      assert length(Regex.scan(~r/data-role="probe-version"/, html)) == 2
    end

    test "draws one of the site's own components, by name, with the bar's assigns as its attributes",
         %{site: site} do
      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: 0,
          active: true
        })

      on_exit(fn -> SiteState.delete(site.id) end)

      component =
        create_component!(
          name: "probe-crumbs-#{System.unique_integer([:positive])}",
          template: ~S|<nav data-role="probe-own" data-version={@version}>own</nav>|,
          attrs: [%{"name" => "version", "type" => "string", "opts" => %{"default" => nil}}],
          active: true,
          precompile: false,
          site_id: site.id
        )

      module = Helpers.module_name(component.name, site.name, "Component")

      on_exit(fn ->
        ModuleCompiler.unload(module)
        CompileFailureState.clear(module)
      end)

      :ok = Translations.put_site(site.id)

      html = bar(%{component: component.name, assigns: %{version: "0.0.6"}}, site.name)

      assert html =~ ~s(data-role="probe-own")
      assert html =~ ~s(data-version="0.0.6")
    end

    test "names a function component only when the module exports it" do
      assert SiteLayout.section_bar_of(%{component: {Picker, :version_select}}).component ==
               {Picker, :version_select}

      ExUnit.CaptureLog.capture_log(fn ->
        assert SiteLayout.section_bar_of(%{component: {Picker, :nowhere}}) == nil
        assert SiteLayout.section_bar_of(%{component: {NoSuchModule, :bar}}) == nil
      end)
    end

    # A SITE'S STYLESHEET IS BUILT FROM ITS OWN TEMPLATES, which name none of the bar's classes.
    test "hands every class it draws with to the site's stylesheet" do
      html =
        bar(%{
          title: "Blog",
          links: [%{label: "Posts", path: "/blog", current: true}, %{label: "Tags", path: "/t"}],
          crumbs: [%{label: "Docs", path: "/docs"}, %{label: "Here"}],
          component: {Picker, :version_select},
          assigns: %{id: "v"}
        })

      drawn =
        ~r/class="([^"]*)"/
        |> Regex.scan(html, capture: :all_but_first)
        |> List.flatten()
        |> Enum.flat_map(&String.split/1)
        |> MapSet.new()

      listed = SiteLayout.classes() |> String.split() |> MapSet.new()

      assert MapSet.subset?(drawn, listed),
             "not in classes/0: #{inspect(MapSet.difference(drawn, listed) |> MapSet.to_list())}"
    end
  end

  describe "assign_frame/1" do
    setup do: plugin!(CategoryFrame)

    test "assigns the frame as @page_languages and @page_section_bar", %{site: site} do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          page: page("/:lang/probe/category/:slug", section: "probe"),
          private: %{site_id: site.id},
          extra: %{"record" => "probe:category"},
          query_params: %{"slug" => "news"},
          page_languages: @editions
        }
      }

      assigns = SiteLayout.assign_frame(socket).assigns

      assert Enum.map(assigns.page_languages, & &1.path) == [
               "/probe/category/news",
               "/ar/probe/category/akhbar",
               "/fa/probe/category/akhbar-fa"
             ]

      # THE CATEGORY ANSWER HALTS THE CHAIN, so the section's bar is the section clause's alone.
      assert assigns.page_section_bar == nil

      socket = put_in(socket.assigns.page, page("/:lang/probe", section: "probe"))
      socket = put_in(socket.assigns.extra, %{})

      assert %{title: "Probe"} = SiteLayout.assign_frame(socket).assigns.page_section_bar
    end
  end

  describe "adopt_pages/3" do
    setup %{site: site} do
      layout = create_layout!(name: SiteLayout.layout_name(), site_id: site.id)
      other = create_layout!(name: "admin-picked", site_id: site.id)

      %{layout: layout, other: other}
    end

    defp page!(site, path, attrs \\ %{}) do
      Page
      |> Ash.Changeset.for_create(
        :master_create,
        Map.merge(
          %{
            name: "probe#{System.unique_integer([:positive])}",
            title: "Probe",
            path: path,
            section: "probe",
            template: "<p>probe</p>",
            format: :heex,
            active: true,
            site_id: site.id
          },
          attrs
        ),
        authorize?: false
      )
      |> Ash.create!()
    end

    defp layout_of(page),
      do: Ash.get!(Page, page.id, action: :read_any, authorize?: false).layout_id

    test "hangs the section's pages that have no layout on site-main, and says which", %{
      site: site,
      layout: layout
    } do
      list = page!(site, "/:lang/probe")

      item =
        page!(site, "/:lang/probe/:slug", %{extra: PageProvision.stamp(%{}, :probe, "1.0").extra})

      assert SiteLayout.layout_id(site.id) == layout.id

      assert SiteLayout.adopt_pages(site, "probe", source: :probe) == [
               "/:lang/probe",
               "/:lang/probe/:slug"
             ]

      assert layout_of(list) == layout.id
      assert layout_of(item) == layout.id
    end

    test "leaves a page an admin moved to another layout, and another section's", %{
      site: site,
      other: other
    } do
      moved = page!(site, "/:lang/probe/moved", %{layout_id: other.id})
      elsewhere = page!(site, "/:lang/elsewhere", %{section: "elsewhere"})

      assert SiteLayout.adopt_pages(site.id, "probe") == []
      assert layout_of(moved) == other.id
      assert layout_of(elsewhere) == nil
    end

    test "leaves a page another extension stamped", %{site: site} do
      theirs =
        page!(site, "/:lang/probe/theirs", %{extra: PageProvision.stamp(%{}, :theirs, nil).extra})

      assert SiteLayout.adopt_pages(site.id, "probe", source: :probe) == []
      assert layout_of(theirs) == nil
    end

    test "changes nothing the second time", %{site: site} do
      page!(site, "/:lang/probe")

      assert SiteLayout.adopt_pages(site.id, "probe") == ["/:lang/probe"]
      assert SiteLayout.adopt_pages(site.id, "probe") == []
    end

    test "does nothing on a site with no site-main" do
      name = "unframed-#{System.unique_integer([:positive])}"
      bare = create_site!(name: name, host: "#{name}.test")
      page!(bare, "/:lang/probe")

      assert SiteLayout.layout_id(bare.id) == nil
      assert SiteLayout.adopt_pages(bare.id, "probe") == []
    end
  end

  describe "the starter's layout" do
    setup %{site: site} do
      dir = Path.join(System.tmp_dir!(), "frame_media_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      Application.put_env(:mishka_cms_core, :media_static_dir, dir)

      on_exit(fn ->
        Application.delete_env(:mishka_cms_core, :media_static_dir)
        File.rm_rf(dir)
      end)

      Ecto.Adapters.SQL.query!(
        MishkaCmsCore.Repo,
        "UPDATE sites SET master = true WHERE id = $1",
        [
          Ecto.UUID.dump!(site.id)
        ]
      )

      :ok
    end

    test "is the one layout_id/1 names", %{site: site} do
      report = StarterContent.seed!(site.id)

      assert SiteLayout.layout_id(site.id) == report.layout_id

      assert [%{name: "site-main"}] =
               Layout
               |> Ash.Query.for_read(:read_any)
               |> Ash.Query.filter(id == ^report.layout_id)
               |> Ash.read!(authorize?: false, page: [limit: 1])
               |> Map.fetch!(:results)
    end
  end

  defp bar(bar, site \\ nil) do
    assigns = %{bar: bar, site: site}

    ~H"""
    <SiteLayout.section_bar bar={@bar} site={@site} />
    """
    |> rendered_to_string()
    |> String.trim()
  end

  defp links(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&{&1 |> LazyHTML.text() |> String.trim(), hd(LazyHTML.attribute(&1, "href"))})
  end
end
