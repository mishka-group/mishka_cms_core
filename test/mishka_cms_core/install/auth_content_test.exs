# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.AuthContentTest do
  @moduledoc """
  The sign-in content every site is given — `MishkaCmsCore.Install.StarterContent.ensure_auth!/1`
  and the job a `Site :create` enqueues for it, `MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker`'s
  `"provision"`.

  `async: false` — the `:env_test?` flag, `SiteState` and the settings cache are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaCmsCore.Accounts.AuthRateLimit
  alias MishkaCmsCore.Install.StarterContent
  alias MishkaCmsCore.Runtime.{Layout, Page, PageProvision, Site, Translation, Translations}
  alias MishkaCmsCore.Runtime.Compilers.{Helpers, LiveViewCompiler}
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.SiteRuntimeWorker
  alias MishkaCmsCore.Settings
  alias MishkaCmsCore.Test.EventCannotRun
  alias MishkaCmsCoreWeb.ReturnTo

  require Ash.Query

  @roles %{
    "/:lang/auth" => "sign_in",
    "/:lang/auth/register" => "register",
    "/:lang/auth/forgot-password" => "forgot_password",
    "/:lang/auth/magic-link" => "magic_link",
    "/:lang/auth/password-reset/:token" => "password_reset",
    "/:lang/auth/confirm-new-user/:token" => "confirm_new_user",
    "/:lang/auth/magic-link/:token" => "magic_link_sign_in",
    "/:lang/auth/sign-out" => "sign_out"
  }

  @robots [%{"tag" => "meta", "attrs" => %{"name" => "robots"}, "content" => "noindex, nofollow"}]

  setup do
    name = "auth#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)
    cache!(site)
    %{site: site}
  end

  describe "ensure_auth!/1" do
    test "writes the auth layout and one page per flow, and says so", %{site: site} do
      report = StarterContent.ensure_auth!(site)

      assert report.layouts == ["auth"]
      assert Enum.sort(report.pages) == Enum.sort(Map.keys(@roles))
      assert report.renamed_pages == []
      assert report.skipped_pages == []
      assert report.translations == 0
      assert report.layout_id == auth_layout(site).id
    end

    test "every page carries its role, the auth layout, and stays out of every index", %{
      site: site
    } do
      %{layout_id: layout_id} = StarterContent.ensure_auth!(site)

      pages = auth_pages(site)
      assert length(pages) == map_size(@roles)

      for page <- pages do
        role = Map.fetch!(@roles, page.path)

        assert page.extra["auth_role"] == role, page.path

        assert Map.get(page.extra, "visitors_only") == if(role == "sign_out", do: nil, else: true),
               page.path

        assert Map.get(page.extra, "signed_in_only") == if(role == "sign_out", do: true),
               page.path

        assert PageProvision.serves_all_languages?(page), page.path
        assert PageProvision.ours?(page, :mishka_cms_core), page.path
        assert page.layout_id == layout_id, page.path
        assert page.precompile, page.path
        assert page.active, page.path
        assert page.permissions == [], page.path
        assert page.section == "auth", page.path
        assert stringified(page.seo_tags) == @robots, page.path
      end
    end

    test "the layout is precompiled, unindexed, titles its pages, and shows the messages", %{
      site: site
    } do
      StarterContent.ensure_auth!(site)
      layout = auth_layout(site)

      assert layout.path == "/layouts/auth"
      assert layout.precompile

      assert stringified(layout.seo_tags) ==
               @robots ++
                 [
                   %{
                     "tag" => "title",
                     "attrs" => %{},
                     "content" => "{{page.title}} · {{site.name}}"
                   }
                 ]

      assert LiveViewCompiler.shows_messages?(layout)
    end

    # CODE A VISITOR NEVER SEES FAIL: the create compiles every page (`PageCodeCompiles`), and the
    # layout and the pages without a live component are rendered here, helpers and all.
    test "the layout and every page compile, and render with the assigns a request has", %{
      site: site
    } do
      StarterContent.ensure_auth!(site)

      layout = auth_layout(site)
      layout_module = compiled!(layout, site, "Layout")

      html =
        %{flash: %{"info" => "Saved"}, page: %{language: "en"}}
        |> layout_module.render({:safe, ~s(<p id="inner">card</p>)})
        |> rendered_to_string()

      assert html =~ ~s(id="inner")
      assert html =~ ~s(id="auth-theme-dark")
      assert html =~ ~s(id="flash-info")
      assert html =~ ~s(id="auth-quote-0")
      assert html =~ ~s(id="auth-quote-2")

      for page <- auth_pages(site) do
        module = compiled!(page, site, "Page")

        unless page.path =~ ":token" do
          html = page_html(module, site)

          refute html =~ "failed to render", page.path
        end
      end
    end

    # WHAT A PRODUCTION INSTALL MAY NOT HAVE, and what the content security policy refuses.
    test "no sign-in markup needs the kit, an inline style or a script", %{site: site} do
      StarterContent.ensure_auth!(site)

      for record <- [auth_layout(site) | auth_pages(site)], source <- sources(record) do
        refute source =~ "chelekom-", record.path
        refute source =~ "<.input", record.path
        refute source =~ "style=", record.path
        refute source =~ "<script", record.path
      end
    end

    # NO ADDRESS ONLY THE OLD MARKETING PROJECT HAD. `/mish-*` pages exist on no installed site; the
    # footer's Docs and Support lead to Mishka's own site.
    test "no sign-in link leads to an address no site has", %{site: site} do
      StarterContent.ensure_auth!(site)

      for record <- [auth_layout(site) | auth_pages(site)], source <- sources(record) do
        refute source =~ "/mish-", record.path
      end

      template = auth_layout(site).template
      assert template =~ ~s(href="https://mishka.tools/cms/extensions/documentation")
      assert template =~ ~s(href="https://mishka.tools/hire-us")
    end

    # EDITABLE IN THE BUILDER, which reads a template through its own parser.
    test "the builder can read every sign-in template", %{site: site} do
      StarterContent.ensure_auth!(site)

      for record <- [auth_layout(site) | auth_pages(site)] do
        assert {:ok, _tree} = Tree.parse(record.template), record.path
      end
    end

    test "a flow page links to its siblings in the language it answers in", %{site: site} do
      publish!(site, ["en", "fa"])
      StarterContent.ensure_auth!(site)
      module = compiled!(page_at(site, "/:lang/auth"), site, "Page")

      html = page_html(module, site, "fa")

      assert html =~ ~s(id="auth-sign-in-form")
      assert html =~ ~s(href="/fa/auth/register")
      assert html =~ ~s(href="/fa/auth/forgot-password")
      assert html =~ ~s(href="/fa/auth/magic-link")

      # The first language unprefixed, the site's default — or prefixed like the others.
      assert page_html(module, site, "en") =~ ~s(href="/auth/register")

      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)
      forget_settings(~w(site.language_urls), [site.id])

      assert page_html(module, site, "en") =~ ~s(href="/en/auth/register")
    end

    # A TOKEN THIS APPLICATION SIGNED IS CARRIED ON, into the links and the form action; a stranger's
    # string is dropped at the door.
    test "a verified return_to travels on, and any other is dropped", %{site: site} do
      StarterContent.ensure_auth!(site)
      module = compiled!(page_at(site, "/:lang/auth"), site, "Page")
      token = ReturnTo.sign(MishkaCmsCore.TestEndpoint, "/en/members")

      carried = page_html(module, site, "en", %{"return_to" => token})
      query = URI.encode_query(%{"return_to" => token})

      assert carried =~ ~s(href="/auth/register?#{query}")
      assert carried =~ "sign_in?#{query}"

      dropped = page_html(module, site, "en", %{"return_to" => "https://evil.example"})

      refute dropped =~ "return_to"
    end

    test "a second run writes nothing", %{site: site} do
      StarterContent.ensure_auth!(site)
      before = {rows(Page, site), rows(Layout, site)}

      report = StarterContent.ensure_auth!(site)

      assert report.layouts == []
      assert report.pages == []
      assert report.renamed_pages == []
      assert report.translations == 0
      assert Enum.all?(report.skipped_pages, &PageProvision.answered?/1)
      assert {rows(Page, site), rows(Layout, site)} == before
    end

    test "a page the site already holds at one of these addresses is left alone", %{site: site} do
      held = create_page!(site_id: site.id, name: "Ours", path: "/:lang/auth")

      report = StarterContent.ensure_auth!(site)

      assert [%{path: "/:lang/auth"}] = report.skipped_pages
      refute "/:lang/auth" in report.pages
      assert length(report.pages) == map_size(@roles) - 1
      assert page_at(site, "/:lang/auth").id == held.id
    end

    test "the pages hang on a layout the site already holds at the auth address", %{site: site} do
      held = create_layout!(site_id: site.id, name: "Sign-in frame", path: "/layouts/auth")

      report = StarterContent.ensure_auth!(site)

      assert report.layouts == []
      assert report.layout_id == held.id
      for page <- auth_pages(site), do: assert(page.layout_id == held.id)
    end

    test "takes a site id, and raises for a site that is not there", %{site: site} do
      assert StarterContent.ensure_auth!(site.id).pages != []
      assert_raise ArgumentError, fn -> StarterContent.ensure_auth!(Ash.UUID.generate()) end
    end

    test "ensure_auth/1 answers a site that is gone instead of raising", %{site: site} do
      assert {:error, :site_not_found} = StarterContent.ensure_auth(Ash.UUID.generate())
      assert {:ok, %{layouts: ["auth"]}} = StarterContent.ensure_auth(site.id)
    end
  end

  # THE LOGIC IS AUTHLIVE'S, run here against the compiled page itself with the socket a request has.
  describe "the events a sign-in page answers" do
    setup %{site: site} do
      StarterContent.ensure_auth!(site)
      :ok
    end

    test "a wrong password says so, and signs nobody in", %{site: site} do
      user = create_user!(site_id: site.id)
      module = compiled!(page_at(site, "/:lang/auth"), site, "Page")

      {:noreply, socket} =
        module.handle_event(
          "sign_in",
          %{"user" => %{"email" => to_string(user.email), "password" => "not-the-password"}},
          socket(site)
        )

      assert socket.assigns.message.title == "Invalid email or password"
      refute socket.redirected
    end

    test "the right password goes to the route that sets the session, return_to and all", %{
      site: site
    } do
      user = create_user!(site_id: site.id)
      module = compiled!(page_at(site, "/:lang/auth"), site, "Page")
      token = ReturnTo.sign(MishkaCmsCore.TestEndpoint, "/en/members")

      {:noreply, socket} =
        module.handle_event(
          "sign_in",
          %{"user" => %{"email" => to_string(user.email), "password" => "Password123!"}},
          socket(site, %{"return_to" => token})
        )

      assert {:redirect, %{to: to}} = socket.redirected

      %URI{path: path, query: query} = URI.parse(to)

      assert path == "/api/auth/user/password/sign_in_with_token"
      assert %{"return_to" => ^token, "token" => signed} = URI.decode_query(query)
      assert is_binary(signed)
    end

    test "a sign-in refused for its rate says how long to wait while auth:live:rate_limited cannot run",
         %{site: site} do
      previous = Application.fetch_env(:mishka_cms_core, AuthRateLimit)
      Application.put_env(:mishka_cms_core, AuthRateLimit, limit: 1)

      on_exit(fn ->
        case previous do
          {:ok, env} -> Application.put_env(:mishka_cms_core, AuthRateLimit, env)
          :error -> Application.delete_env(:mishka_cms_core, AuthRateLimit)
        end
      end)

      EventCannotRun.stub!("auth:live:rate_limited")
      user = create_user!(site_id: site.id)
      module = compiled!(page_at(site, "/:lang/auth"), site, "Page")
      params = %{"user" => %{"email" => to_string(user.email), "password" => "not-the-password"}}

      {:noreply, _first} = module.handle_event("sign_in", params, socket(site))
      {:noreply, socket} = module.handle_event("sign_in", params, socket(site))

      assert socket.assigns.message.id == "auth-rate-limited"
      refute socket.redirected
    end

    test "a rate refusal says how long to wait in AuthRateLimit's own words", %{site: site} do
      module = compiled!(page_at(site, "/:lang/auth"), site, "Page")

      for seconds <- [1, 2, 59, 60, 61, 90, 3600],
          action <- [:sign_in, :reset_request, :magic_link] do
        limited = %{action: action, key: :ip, retry_after: seconds}

        assert module.rate_limit_message(limited) ==
                 limited |> AuthRateLimit.describe() |> Map.put(:id, "auth-rate-limited")
      end
    end

    test "a reset request answers the same whether or not the account exists", %{site: site} do
      module = compiled!(page_at(site, "/:lang/auth/forgot-password"), site, "Page")

      {:noreply, socket} =
        module.handle_event(
          "request_reset",
          %{"user" => %{"email" => "nobody@example.com"}},
          socket(site)
        )

      assert socket.assigns.sent == %{
               email: "nobody@example.com",
               text: "If an account exists for that email, a reset link is on its way."
             }

      assert socket.assigns.reset_form == nil
    end

    test "the register form scores the password as it is typed, and the eye shows both", %{
      site: site
    } do
      module = compiled!(page_at(site, "/:lang/auth/register"), site, "Page")

      typed = %{
        "email" => "new@example.com",
        "password" => "Abcdefg1!",
        "password_confirmation" => "Abcdefg1!"
      }

      {:noreply, socket} =
        module.handle_event("validate_register", %{"user" => typed}, socket(site))

      assert module.password_score(socket.assigns.register_form) == 4
      assert module.confirm_state(socket.assigns.register_form).matched?

      {:noreply, socket} = module.handle_event("toggle_register_password", %{}, socket)

      assert socket.assigns.reg_pw_visible
    end
  end

  describe "the Persian words" do
    test "a site publishing in fa gets a row for every word the layout and the pages ask for", %{
      site: site
    } do
      publish!(site, ["en", "fa"])

      report = StarterContent.ensure_auth!(site)
      seeded = fa_rows(site)

      assert report.translations == map_size(seeded)

      asked =
        [auth_layout(site) | auth_pages(site)]
        |> Enum.flat_map(&sources/1)
        |> Enum.flat_map(&Translations.keys/1)
        |> Enum.uniq()

      assert asked != []

      for key <- asked do
        assert is_binary(seeded[key]) and seeded[key] != "" and seeded[key] != key,
               "no Persian for #{inspect(key)}"
      end
    end

    test "a site that does not publish in fa gets none", %{site: site} do
      assert StarterContent.ensure_auth!(site).translations == 0
      assert fa_rows(site) == %{}
    end

    test "a row the site holds keeps its value on a second run", %{site: site} do
      publish!(site, ["en", "fa"])
      StarterContent.ensure_auth!(site)

      row = fa_row!(site, "Sign in")

      row
      |> Ash.Changeset.for_update(:master_update, %{value: "ورود به سایت"}, authorize?: false)
      |> Ash.update!()

      assert StarterContent.ensure_auth!(site).translations == 0
      assert fa_row!(site, "Sign in").value == "ورود به سایت"
    end

    # THE CODE'S WORDS TOO: the rate-limit texts, the strength labels and the quotes live in the
    # pages' events and helpers, and Remove unused must not take them.
    test "every word seeded is in use, so Remove unused lists none of them", %{site: site} do
      publish!(site, ["en", "fa"])
      StarterContent.ensure_auth!(site)
      master = create_user_with_permissions!(["admin:dashboard:*"])

      seeded = fa_rows(site)
      used = Translations.used_keys(site.id)

      for key <- ["Too short", "Strong", "Try again in 1 minute.", "Owner · Pão & Sal"] do
        assert Map.has_key?(seeded, key), "#{key} is not seeded"
      end

      for {key, _value} <- seeded, do: assert(key in used, "#{key} is listed as unused")
      assert Translations.unused_ids(master, site.id) == []
    end

    # ANY MIX OF LANGUAGES: built-in words are written for each language that has them, and every
    # other one is served the English, in its own address, until its rows are filled in.
    test "a site publishing in fr, ru, fa and en gets Persian words only, and every language its pages",
         %{site: site} do
      publish!(site, ["fr", "ru", "fa", "en"])

      report = StarterContent.ensure_auth!(site)

      assert report.translations == map_size(fa_rows(site))
      assert report.translations > 0
      assert rows_in(site, "fr") == %{} and rows_in(site, "ru") == %{}

      sign_in = compiled!(page_at(site, "/:lang/auth"), site, "Page")

      for {language, register} <- [{"fr", "/auth/register"}, {"ru", "/ru/auth/register"}] do
        html = page_html(sign_in, site, language)
        assert html =~ "Welcome back"
        assert html =~ ~s(href="#{register}")
      end
    end

    # NO LANGUAGE ON THE PAGE (the builder's canvas draws it without one): the links take the site's
    # primary language, never a fixed one.
    test "the links fall back to the site's primary language", %{site: site} do
      publish!(site, ["ru", "en"])
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)
      forget_settings(~w(site.language_urls), [site.id])
      StarterContent.ensure_auth!(site)

      sign_in = compiled!(page_at(site, "/:lang/auth"), site, "Page")

      assert page_html(sign_in, site, nil) =~ ~s(href="/ru/auth/register")
    end

    test "a site that gains fa later is given the words it is missing", %{site: site} do
      StarterContent.ensure_auth!(site)
      publish!(site, ["en", "fa"])

      assert StarterContent.ensure_auth!(site).translations > 0
      assert fa_row!(site, "Welcome back").value == "خوش برگشتید"
    end
  end

  describe "a site created in the admin" do
    test "enqueues its sign-in pages" do
      jobs_off()
      site = created_site!()

      assert_enqueued(
        worker: SiteRuntimeWorker,
        queue: :maintenance,
        args: provision(site),
        meta: %{slug: "site_provision:#{site.id}"}
      )
    end

    test "enqueues nothing when the caller writes them itself" do
      jobs_off()
      site = created_site!(%{auth_pages: :inline})

      refute_enqueued(worker: SiteRuntimeWorker, args: %{"site_id" => site.id})
    end

    test "enqueues nothing under the test flag" do
      site = created_site!()

      refute_enqueued(worker: SiteRuntimeWorker, args: %{"site_id" => site.id})
    end

    # A RENAME WAITING BESIDE IT TAKES A SLOT OF ITS OWN, and does not replace the provision's args.
    test "keeps the job when the site is renamed before it runs" do
      jobs_off()
      site = created_site!()

      renamed = %{name: "renamed#{System.unique_integer([:positive])}"}

      site
      |> Ash.Changeset.for_update(:update, renamed, authorize?: false)
      |> Ash.update!()

      assert_enqueued(worker: SiteRuntimeWorker, args: provision(site))

      assert_enqueued(
        worker: SiteRuntimeWorker,
        args: %{"transition" => "rename", "site_id" => site.id}
      )
    end

    test "the job writes the sign-in content", %{site: site} do
      assert :ok = perform_job(SiteRuntimeWorker, provision(site))

      assert length(auth_pages(site)) == map_size(@roles)
      assert auth_layout(site)
    end

    test "the job queues the site's JS build, under the name it has now", %{site: site} do
      assert :ok = perform_job(SiteRuntimeWorker, provision(site))

      assert_enqueued(
        worker: MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker,
        args: %{"data" => %{"type" => "js", "site_id" => site.id, "site_name" => site.name}}
      )

      renamed = %{site | name: "renamed#{System.unique_integer([:positive])}"}
      cache!(renamed)
      assert :ok = perform_job(SiteRuntimeWorker, provision(site))

      assert_enqueued(
        worker: MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker,
        args: %{"data" => %{"type" => "js", "site_id" => site.id, "site_name" => renamed.name}}
      )
    end

    test "the job for a site that is gone is cancelled" do
      gone = %{id: Ash.UUID.generate(), name: "gone"}

      assert {:cancel, :site_not_found} = perform_job(SiteRuntimeWorker, provision(gone))
    end
  end

  # Reports what it heard, and how much of the site's sign-in content was written by then.
  defmodule BeforeAuthPages do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:site:before_auth_pages"

    @impl true
    def call(payload, _meta) do
      send(
        self(),
        {:before_auth_pages, payload, MishkaCmsCore.Install.AuthContentTest.held(payload.site_id)}
      )

      {:reply, payload}
    end
  end

  defmodule AfterAuthPages do
    @moduledoc false
    use MishkaInstaller.Event.Hook, event: "runtime:site:after_auth_pages"

    @impl true
    def call(payload, _meta) do
      send(
        self(),
        {:after_auth_pages, payload, MishkaCmsCore.Install.AuthContentTest.held(payload.site_id)}
      )

      {:reply, payload}
    end
  end

  describe "events" do
    setup do
      plugin!(BeforeAuthPages, "runtime:site:before_auth_pages")
      plugin!(AfterAuthPages, "runtime:site:after_auth_pages")
    end

    test "runtime:site:before_auth_pages is heard before anything is written, with the site", %{
      site: site
    } do
      StarterContent.ensure_auth!(site)

      assert_received {:before_auth_pages, payload, held}
      assert payload == %{site_id: site.id, site_name: site.name}
      assert held == %{layouts: 0, pages: 0}
    end

    test "runtime:site:after_auth_pages is heard once it is written, with the report and the site",
         %{site: site} do
      report = StarterContent.ensure_auth!(site)

      assert_received {:after_auth_pages, payload, held}
      assert payload == Map.put(report, :site_id, site.id)
      assert held == %{layouts: 1, pages: map_size(@roles)}
    end

    test "both are heard on a run that finds everything written", %{site: site} do
      StarterContent.ensure_auth!(site)
      assert_received {:before_auth_pages, _payload, _held}
      assert_received {:after_auth_pages, _payload, _held}

      report = StarterContent.ensure_auth!(site)

      assert_received {:before_auth_pages, %{site_id: site_id}, %{pages: pages}}
      assert site_id == site.id
      assert pages == map_size(@roles)
      assert_received {:after_auth_pages, payload, _held}
      assert payload == Map.put(report, :site_id, site.id)
      assert report.pages == []
    end
  end

  @doc false
  def held(site_id) do
    %{
      layouts: site_id |> rows_of(Layout) |> Enum.count(&(&1.path == "/layouts/auth")),
      pages: site_id |> rows_of(Page) |> Enum.count(&(&1.section == "auth"))
    }
  end

  defp rows_of(site_id, resource) do
    resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> Map.fetch!(:results)
  end

  defp plugin!(module, event) do
    {:ok, _} =
      MishkaInstaller.Event.Event.write(%{
        name: module,
        event: event,
        extension: :mishka_installer,
        status: :started
      })

    :ok = MishkaInstaller.Event.EventHandler.do_compile(event, :start, false)
    on_exit(fn -> MishkaInstaller.Event.Event.unregister(:name, module, false) end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp cache!(site) do
    :ok =
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: 0,
        active: true,
        master: false
      })

    on_exit(fn -> SiteState.delete(site.id) end)
  end

  defp provision(site) do
    %{
      "site_id" => site.id,
      "site_name" => site.name,
      "old_name" => site.name,
      "transition" => "provision"
    }
  end

  defp jobs_off do
    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)
  end

  defp created_site!(context \\ %{}) do
    name = "auth-new#{System.unique_integer([:positive])}"

    site =
      Site
      |> Ash.Changeset.for_create(:create, %{name: name, host: "#{name}.test"},
        authorize?: false,
        context: context
      )
      |> Ash.create!()

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp publish!(site, languages) do
    {:ok, _setting} =
      Settings.put("site.languages", languages, site_id: site.id, category: "general")

    forget_settings(~w(site.languages), [site.id])
  end

  defp compiled!(record, site, kind) do
    module = Helpers.module_name(record.id, site.name, kind)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    assert {:ok, ^module} =
             ModuleCompilerHandler.compile_or_return_module(
               module,
               record.path,
               site.name,
               site.id
             )

    module
  end

  defp page_html(module, site, language \\ "en", query \\ %{}) do
    :ok = Translations.put_site(site.id)

    %{
      page: %{language: language},
      query_params: Map.merge(%{"lang" => language}, query),
      flash: %{},
      current_tenant: site.id,
      current_site: site
    }
    |> module.render()
    |> rendered_to_string()
  end

  defp socket(site, query \\ %{}) do
    %Phoenix.LiveView.Socket{
      endpoint: MishkaCmsCore.TestEndpoint,
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_site: site,
        current_tenant: site.id,
        page: %{language: "en"},
        query_params: Map.merge(%{"lang" => "en"}, query)
      }
    }
  end

  defp sources(record) do
    [record.template] ++
      Enum.map(Map.get(record, :helpers) || [], & &1.code) ++
      Enum.map(Map.get(record, :events) || [], &(&1[:code] || &1["code"]))
  end

  defp fa_rows(site), do: rows_in(site, "fa")

  # Rows with a value only: saving a page registers an empty row for every word it asks for.
  defp rows_in(site, language) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and language == ^language and not is_nil(value))
    |> Ash.read!(authorize?: false, page: false)
    |> Map.new(&{&1.key, &1.value})
  end

  defp fa_row!(site, key) do
    Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and language == "fa" and key == ^key)
    |> Ash.read_one!(authorize?: false)
  end

  defp auth_pages(site), do: Page |> rows(site) |> Enum.filter(&(&1.section == "auth"))

  defp page_at(site, path), do: Page |> rows(site) |> Enum.find(&(&1.path == path))

  defp auth_layout(site), do: Layout |> rows(site) |> Enum.find(&(&1.path == "/layouts/auth"))

  defp rows(resource, site) do
    resource
    |> Ash.Query.for_read(:read_any)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> Map.fetch!(:results)
    |> Enum.sort_by(& &1.id)
  end

  defp stringified(tags), do: tags |> Jason.encode!() |> Jason.decode!()
end
