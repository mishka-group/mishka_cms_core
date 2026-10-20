# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.LiveViewHelpersTranslationTest do
  @moduledoc """
  `t/1` and `site_path/2` inside a template that was compiled from the database, and the import list
  that puts them there.

  A runtime template never passes a site or a language to `t/1` — both are read off the process
  rendering it — so what is proved here is the path a visitor takes: a component saved with
  `t("…")` in its markup, built on its first render, drawn in the language the process answers in —
  and in a task the component starts, which answers what the render does. And `imports/1`, because
  a component whose own helpers define a `t` — or a `captcha` — is a compile error the moment a
  second one is imported beside it.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.{CspNonce, LiveViewHelpers, Translation, Translations}
  alias MishkaCmsCore.Runtime.Resources.Embeddeds.Helper
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SiteState, TranslationsState}
  alias MishkaCmsCore.Settings

  require Ash.Query

  @moduletag :integration

  @categories "دسته‌بندی‌ها"

  describe "imports/1 — what a runtime template imports from LiveViewHelpers" do
    test "is component/1,2, captcha/1, sign_in_providers/1, rich_content/1, t/1,2, csp_nonce/0 and site_path/2 when there are no helpers" do
      all = [
        component: 1,
        component: 2,
        captcha: 1,
        sign_in_providers: 1,
        rich_content: 1,
        t: 1,
        t: 2,
        csp_nonce: 0,
        site_path: 2
      ]

      assert LiveViewHelpers.imports(nil) == all
      assert LiveViewHelpers.imports([]) == all
    end

    # A helper reaches the compiler as an atom-keyed map from a builder save, a string-keyed one from
    # a kit bundle, and the embedded struct from a row read back — all three name the same `t`.
    test "leaves t out, and keeps component, when a helper is named t" do
      for helper <- [
            %{name: "t", args: "key", code: "key"},
            %{"name" => "t", "args" => "key", "code" => "key"},
            %Helper{name: "t", args: "key", code: "key"}
          ] do
        assert LiveViewHelpers.imports([helper]) == [
                 component: 1,
                 component: 2,
                 captcha: 1,
                 sign_in_providers: 1,
                 rich_content: 1,
                 csp_nonce: 0,
                 site_path: 2
               ],
               "t is still imported beside #{inspect(helper)}"
      end
    end

    test "keeps t for a helper named anything else, even one that starts with t" do
      for name <- ["tone", "t_label", "at", "format"] do
        imports = LiveViewHelpers.imports([%{name: name, args: "x", code: "x"}])

        assert {:t, 1} in imports, "t/1 went missing beside a helper named #{name}"
        assert {:t, 2} in imports, "t/2 went missing beside a helper named #{name}"
      end
    end

    test "finds the t among several helpers" do
      helpers = [%{name: "tone"}, %{"name" => "t"}, %{name: "format"}]

      assert LiveViewHelpers.imports(helpers) == [
               component: 1,
               component: 2,
               captcha: 1,
               sign_in_providers: 1,
               rich_content: 1,
               csp_nonce: 0,
               site_path: 2
             ]
    end

    test "leaves out any name a helper defines, captcha as much as t" do
      assert LiveViewHelpers.imports([%{name: "captcha"}]) ==
               [
                 component: 1,
                 component: 2,
                 sign_in_providers: 1,
                 rich_content: 1,
                 t: 1,
                 t: 2,
                 csp_nonce: 0,
                 site_path: 2
               ]
    end

    test "and rich_content, for a component that draws its own" do
      assert LiveViewHelpers.imports([%{"name" => "rich_content"}]) ==
               [
                 component: 1,
                 component: 2,
                 captcha: 1,
                 sign_in_providers: 1,
                 t: 1,
                 t: 2,
                 csp_nonce: 0,
                 site_path: 2
               ]

      assert LiveViewHelpers.imports([%{name: "site_path"}]) ==
               [
                 component: 1,
                 component: 2,
                 captcha: 1,
                 sign_in_providers: 1,
                 rich_content: 1,
                 t: 1,
                 t: 2,
                 csp_nonce: 0
               ]
    end
  end

  # ONE LINK, BOTH MODES: a template names the stored path and the language, and the address follows
  # the site's `site.language_urls`.
  describe "site_path/2" do
    setup :site

    test "is the public address on the site this process renders for", %{site: site} do
      answering_in(site, "en")

      assert LiveViewHelpers.site_path("/:lang/blog", "en") == "/blog"
      assert LiveViewHelpers.site_path("/:lang/blog", "fa") == "/fa/blog"
      assert LiveViewHelpers.site_path("/:lang", nil) == "/"

      assert LiveViewHelpers.site_path("/:lang/blog/:slug", %{"lang" => "fa", "slug" => "a b"}) ==
               "/fa/blog/a%20b"

      refute LiveViewHelpers.site_path("/:lang/blog", "de")

      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert LiveViewHelpers.site_path("/:lang/blog", "en") == "/en/blog"
      assert LiveViewHelpers.site_path("/:lang", nil) == "/en"
    end

    test "is imported into a compiled component", %{site: site} do
      component =
        make_component(
          site,
          ~s|<a class="sp-probe" href={site_path("/:lang/about", "en")}>en</a><a href={site_path("/:lang/about", "fa")}>fa</a>|
        )

      answering_in(site, "en")
      html = render(component, site)

      assert html =~ ~s(href="/about")
      assert html =~ ~s(href="/fa/about")

      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      assert render(component, site) =~ ~s(href="/en/about")
    end
  end

  describe "t/1 in a compiled component" do
    setup :site

    test "renders the site's translation in the language the process answers in", %{site: site} do
      component = make_component(site, ~s|<h2 class="tr-probe">{t("Categories")}</h2>|)
      cache!(site.id, "fa", "Categories", @categories)
      answering_in(site, "fa")

      html = render(component, site)

      assert html =~ "tr-probe"
      assert html =~ @categories
      refute html =~ "Categories"
    end

    # The two ZWNJs are what make it the word and not three words run together, and HEEx's escaping
    # is the one step between the cache and the page that could have touched them.
    test "keeps every zero-width non-joiner of a Persian value", %{site: site} do
      component = make_component(site, ~s|<h2>{t("Categories")}</h2>|)
      cache!(site.id, "fa", "Categories", @categories)
      answering_in(site, "fa")

      html = render(component, site)

      assert html |> String.codepoints() |> Enum.count(&(&1 == "\u200C")) == 2
    end

    test "renders the key itself when nobody has translated it", %{site: site} do
      component = make_component(site, ~s|<h2>{t("Categories")}</h2>|)
      answering_in(site, "fa")

      assert render(component, site) =~ "<h2>Categories</h2>"
    end

    test "renders the key in a language the translation was not written in", %{site: site} do
      component = make_component(site, ~s|<h2>{t("Categories")}</h2>|)
      cache!(site.id, "fa", "Categories", @categories)
      answering_in(site, "en")

      html = render(component, site)

      assert html =~ "<h2>Categories</h2>"
      refute html =~ @categories
    end

    test "falls back to the global translation when the site has none", %{site: site} do
      key = "Global categories #{unique()}"
      component = make_component(site, ~s|<h2>{t("#{key}")}</h2>|)
      cache!(nil, "fa", key, @categories)
      answering_in(site, "fa")

      assert render(component, site) =~ "<h2>#{@categories}</h2>"
    end

    test "prefers the site's own translation to the global one", %{site: site} do
      key = "Shared categories #{unique()}"
      component = make_component(site, ~s|<h2>{t("#{key}")}</h2>|)
      cache!(nil, "fa", key, "سراسری")
      cache!(site.id, "fa", key, @categories)
      answering_in(site, "fa")

      html = render(component, site)

      assert html =~ "<h2>#{@categories}</h2>"
      refute html =~ "سراسری"
    end

    # Another site's row sits in the same table under the same key; the process names whose words
    # it reads, so a neighbour's translation must never surface on this one.
    test "never renders another site's translation", %{site: site} do
      other = create_site!()
      component = make_component(site, ~s|<h2>{t("Categories")}</h2>|)
      cache!(other.id, "fa", "Categories", "مال دیگری")
      answering_in(site, "fa")

      assert render(component, site) =~ "<h2>Categories</h2>"
    end

    test "fills its bindings into the translation, and into the key when untranslated",
         %{site: site} do
      component = make_component(site, ~s|<p>{t("Read %{count} posts", count: 3)}</p>|)
      answering_in(site, "fa")

      assert render(component, site) =~ "<p>Read 3 posts</p>"

      cache!(site.id, "fa", "Read %{count} posts", "%{count} نوشته را بخوانید")

      assert render(component, site) =~ "<p>3 نوشته را بخوانید</p>"
    end

    # A translation is text somebody typed into the admin. It must reach the page as text.
    test "escapes a translation that carries markup", %{site: site} do
      component = make_component(site, ~s|<h2>{t("Categories")}</h2>|)
      cache!(site.id, "fa", "Categories", ~s|<script>alert("x")</script>|)
      answering_in(site, "fa")

      html = render(component, site)

      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>"
    end

    # The lookup is at render, not baked in at compile — a translation saved in the admin shows on
    # the next render of a component that is already a module, with nothing rebuilt.
    test "reads the cache on every render of a module built once", %{site: site} do
      component = make_component(site, ~s|<h2>{t("Categories")}</h2>|)
      answering_in(site, "fa")

      assert render(component, site) =~ "<h2>Categories</h2>"
      assert Helpers.loaded?(module_for(component, site))

      cache!(site.id, "fa", "Categories", @categories)

      assert render(component, site) =~ "<h2>#{@categories}</h2>"
    end
  end

  describe "from a saved template to a rendered translation" do
    setup :site

    # The whole loop an author and a translator walk: the save registers the key in every language
    # the site publishes in, the translator fills the Persian row, the broadcast reaches the cache,
    # and the next render reads it.
    test "a key the save registered, once translated, is what renders", %{site: site} do
      key = "Categories #{unique()}"
      component = make_component(site, ~s|<h2>{t("#{key}")}</h2>|)

      rows =
        Translation
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(site_id == ^site.id and key == ^key)
        |> Ash.read!(authorize?: false)

      assert rows |> Enum.map(& &1.language) |> Enum.sort() == ["en", "fa"]
      assert Enum.all?(rows, &is_nil(&1.value))

      on_exit(fn -> TranslationsState.put(site.id, "fa", key, nil) end)

      rows
      |> Enum.find(&(&1.language == "fa"))
      |> Ash.Changeset.for_update(:update, %{value: @categories},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!(authorize?: false)

      :sys.get_state(TranslationsState)
      answering_in(site, "fa")

      assert render(component, site) =~ "<h2>#{@categories}</h2>"
    end
  end

  # A TASK IS ANOTHER PROCESS, and the site and the nonce a template reads live in the process
  # dictionary of the one rendering it. `MishkaGervaz.Messages.start_async/4` hands both to the task
  # because `LiveViewHelpers.carry_into_tasks/0` registered them when the core started.
  describe "in a task a compiled component starts with MishkaGervaz.Messages.start_async/4" do
    setup [:site, :task_component]

    test "site_path/2, t/1,2 and csp_nonce/0 answer what they answer outside it", %{
      module: module
    } do
      outside = module.answers()

      assert outside.fa == "/fa/about"
      assert outside.primary == "/about"
      assert outside.captured == "/fa/blog/a%20b"
      assert outside.word == @categories
      assert outside.bound == "3 نوشته را بخوانید"
      assert is_binary(outside.nonce)

      socket = module.in_task(connected_socket())
      {_ref, pid, _kind} = socket.private.live_async[:probe]
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}

      assert_received {:phoenix, :async_result, {:start, {_ref, _cid, :probe, {:ok, in_task}}}}
      assert in_task == outside
    end

    # WHAT THE CARRY IS FOR: the same function in a process nobody handed anything renders for no
    # site, in the default language.
    test "and a task started any other way answers for no site", %{module: module} do
      in_task = Task.async(fn -> module.answers() end) |> Task.await()

      assert in_task.fa == nil
      assert in_task.word == "Categories"
      assert in_task.nonce == nil
    end
  end

  describe "a component whose own helpers define t" do
    setup :site

    # WHY `imports/1` EXISTS. Importing `t/1` into a module that defines one is a compile error, so a
    # component that saved before `t/1` was imported everywhere would stop building the day it was.
    # Its own `t` wins, even over a translation the cache holds for the same key.
    test "still compiles, and its own t answers", %{site: site} do
      component =
        make_component(site, ~s|<span class="own-t">{t("Hello")}</span>|,
          helpers: [%{name: "t", args: "key", code: ~s("own:" <> key)}]
        )

      cache!(site.id, "fa", "Hello", "سلام")
      answering_in(site, "fa")

      html = render(component, site)

      assert Helpers.loaded?(module_for(component, site))
      refute html =~ "failed to render"
      assert html =~ "own:Hello"
      refute html =~ "سلام"
    end
  end

  # The site's name and host are unique per test: `SiteState.save/1` refuses a name or host another
  # row already holds, and a refused save leaves every render here answering the placeholder.
  defp site(_context) do
    n = unique()
    site = create_site!(name: "translated-site-#{n}", host: "translated-#{n}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> SiteState.delete(site.id) end)

    forget_settings(~w(site.languages site.language_urls), [site.id])
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    %{site: site}
  end

  # A component whose helpers start a task that answers with what the imports return, and answer
  # with the same themselves.
  defp task_component(%{site: site}) do
    helpers = [
      %{
        name: "in_task",
        args: "socket",
        code: "MishkaGervaz.Messages.start_async(socket, :probe, fn -> answers() end)"
      },
      %{
        name: "answers",
        args: "",
        code: ~S"""
        %{
          fa: site_path("/:lang/about", "fa"),
          primary: site_path("/:lang/about", nil),
          captured: site_path("/:lang/blog/:slug", %{"lang" => "fa", "slug" => "a b"}),
          word: t("Categories"),
          bound: t("Read %{count} posts", count: 3),
          nonce: csp_nonce()
        }
        """
      }
    ]

    component = make_component(site, ~s|<span class="task-probe">probe</span>|, helpers: helpers)

    cache!(site.id, "fa", "Categories", @categories)
    cache!(site.id, "fa", "Read %{count} posts", "%{count} نوشته را بخوانید")
    answering_in(site, "fa")
    :ok = CspNonce.put("nonce-#{unique()}")

    assert render(component, site) =~ "task-probe"

    %{module: module_for(component, site)}
  end

  defp make_component(site, template, opts \\ []) do
    component =
      create_component!(
        Keyword.merge(
          [name: "translated-#{unique()}", template: template, site_id: site.id],
          opts
        )
      )

    module = module_for(component, site)

    on_exit(fn ->
      ModuleCompiler.unload(module)
      CompileFailureState.clear(module)
    end)

    component
  end

  defp module_for(component, site),
    do: Helpers.module_name(component.name, site.name, "Component")

  defp answering_in(site, language) do
    :ok = Translations.put_site(site.id)
    Gettext.put_locale(MishkaCmsCore.Gettext, language)
  end

  defp cache!(site_id, language, key, value) do
    :ok = TranslationsState.put(site_id, language, key, value)
    on_exit(fn -> TranslationsState.put(site_id, language, key, nil) end)
  end

  defp render(component, site) do
    %{component_name: component.name, site: site.name}
    |> LiveViewHelpers.component()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # A socket `Phoenix.LiveView.start_async/4` starts a task for: connected, its answer sent to this
  # process.
  defp connected_socket do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      private: %{live_temp: %{}, lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }
  end

  defp unique, do: System.unique_integer([:positive])
end
