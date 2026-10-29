# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.TokensTest do
  @moduledoc """
  The design tokens a site renders from, read out of its own stylesheet rows.

  A token is a custom-property declaration in a `:root` block of an `:app_base` or `:theme` sheet —
  the two kinds the compiler injects BEFORE class generation, which is the only place a declaration
  can be for Tailwind to resolve `bg-danger-light` through it.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.Compilers.TailwindCompiler
  alias MishkaCmsCore.Runtime.PageBuilder.Tokens
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  require Ash.Query

  # WHO WRITES A TOKEN: the Studio writes as the signed-in user, and a master may write any site's
  # override sheet and the shared one.
  defp builder, do: create_user_with_permissions!(["*"])

  @theme """
  :root {
    --danger-light: #de1135;
    --danger-hover-light: #bb032a;
    --space-unit: 0.25rem;
    --ease-out: cubic-bezier(0, 0, 0.2, 1);
    --font-sans: Manrope;
  }

  @theme {
    --color-danger-light: var(--danger-light);
    --color-danger-hover-light: var(--danger-hover-light);
  }
  """

  setup do
    site = create_site!(name: "tokens-site", host: "tokens.local", active: true)

    {:ok, sheet} =
      MishkaCmsCore.Runtime.Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "test-theme-#{System.unique_integer([:positive])}",
          kind: :theme,
          content: @theme,
          site_id: nil,
          active: true
        },
        authorize?: false
      )
      |> Ash.create()

    %{site: site, sheet: sheet}
  end

  describe "list/1" do
    test "reads every declaration out of the theme sheet", %{site: site} do
      keys = site.id |> Tokens.list() |> Enum.map(& &1.key)

      assert "danger-light" in keys
      assert "space-unit" in keys
      assert "ease-out" in keys
    end

    # The Studio's control has to match what the value IS: a colour needs a swatch, a length needs a
    # number. The kit names tokens by role (`--danger-light`), so the value is the only signal.
    test "sorts a token into a category by its value, not its name", %{site: site} do
      by_key = site.id |> Tokens.list() |> Map.new(&{&1.key, &1})

      assert by_key["danger-light"].category == "color"
      assert by_key["space-unit"].category == "space"
      assert by_key["ease-out"].category == "motion"
      assert by_key["font-sans"].category == "type"
    end

    test "counts how many declarations resolve through a token", %{site: site} do
      by_key = site.id |> Tokens.list() |> Map.new(&{&1.key, &1})

      # `--color-danger-light: var(--danger-light)` in the @theme block.
      assert by_key["danger-light"].usage == 1
      assert by_key["font-sans"].usage == 0
    end

    test "gives each token a readable label", %{site: site} do
      by_key = site.id |> Tokens.list() |> Map.new(&{&1.key, &1})

      assert by_key["danger-hover-light"].label == "Danger hover light"
    end
  end

  describe "put/4 on a token the site declares itself" do
    setup %{site: site} do
      {:ok, own} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "site-theme-#{System.unique_integer([:positive])}",
            kind: :theme,
            content: ":root { --danger-light: #111111; }",
            site_id: site.id,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      %{own: own}
    end

    test "writes the site's own sheet and leaves the shared one alone", %{
      site: site,
      sheet: shared,
      own: own
    } do
      before = sheet_count(site.id)

      assert {:ok, token} = Tokens.put(builder(), site.id, "--danger-light", "#ff0000")
      assert token.value == "#ff0000"

      assert reload(own).content =~ "--danger-light: #ff0000;"
      assert reload(shared).content =~ "--danger-light: #de1135;"
      assert sheet_count(site.id) == before, "a sheet was created where one already existed"
    end
  end

  # A SHARED SHEET IS EVERY SITE'S. The kit ships its tokens in a global `:theme` row, so almost
  # every token a site can see is declared there — and `declaring_sheet/2` used to hand that row
  # straight back and rewrite it. One site's Studio changed `--danger-light` and every other site on
  # the installation went red with it, silently, with nothing in either editor to say so.
  #
  # The cascade already has the answer: a site's own `:theme` row loads after the global ones, so an
  # override is a declaration in the site's own sheet. The Studio writes one — creating the sheet the
  # first time — and the shared row is never touched by a tenant at all.
  describe "put/4 on a token only the shared sheet declares" do
    test "does not touch the shared sheet", %{site: site, sheet: shared} do
      assert {:ok, token} = Tokens.put(builder(), site.id, "--danger-light", "#ff0000")
      assert token.value == "#ff0000"

      assert reload(shared).content =~ "--danger-light: #de1135;",
             "one site's Studio rewrote the stylesheet every site renders from"
    end

    test "and the site reads its own value back while the shared one is unchanged", %{site: site} do
      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#ff0000")

      assert value_of(Tokens.list(site.id), "danger-light") == "#ff0000"
      assert value_of(Tokens.list(nil), "danger-light") == "#de1135"
    end

    test "another site is untouched", %{site: site} do
      other = create_site!(name: "tokens-other", host: "other.tokens.local", active: true)

      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#ff0000")

      assert value_of(Tokens.list(other.id), "danger-light") == "#de1135"
    end

    test "one override sheet serves every token, however many times it is set", %{site: site} do
      before = sheet_count(site.id)

      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#ff0000")
      assert {:ok, _} = Tokens.put(builder(), site.id, "--space-unit", "0.5rem")
      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#00ff00")

      assert sheet_count(site.id) == before + 1, "a sheet was created per write"

      tokens = Tokens.list(site.id)
      assert value_of(tokens, "danger-light") == "#00ff00"
      assert value_of(tokens, "space-unit") == "0.5rem"
    end

    # A master edits globally — no site is being scoped to, so the shared row IS the target.
    test "but a master writing without a site rewrites the shared sheet", %{sheet: shared} do
      assert {:ok, _} = Tokens.put(builder(), nil, "--danger-light", "#ff0000")

      assert reload(shared).content =~ "--danger-light: #ff0000;"
    end
  end

  describe "put/4" do
    test "accepts any legitimate CSS value", %{site: site} do
      assert {:ok, _} = Tokens.put(builder(), site.id, "--space-unit", "0.5rem")
      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "rgba(0, 0, 0, 0.5)")

      assert {:ok, _} =
               Tokens.put(builder(), site.id, "--danger-hover-light", "var(--danger-light)")

      tokens = Tokens.list(site.id)
      assert value_of(tokens, "space-unit") == "0.5rem"
      assert value_of(tokens, "danger-light") == "rgba(0, 0, 0, 0.5)"
    end

    # A value is written verbatim into a stylesheet, so it may not escape its own declaration.
    test "refuses a value that would break out of the declaration", %{site: site} do
      assert {:error, :invalid_value} = Tokens.put(builder(), site.id, "--danger-light", "red; }")

      assert {:error, :invalid_value} =
               Tokens.put(builder(), site.id, "--danger-light", "red /* oops")

      assert {:error, :blank} = Tokens.put(builder(), site.id, "--danger-light", "   ")
    end

    # A token nothing resolves through is a line of dead CSS, and silently adding one would look
    # like it worked.
    test "refuses a token the site does not declare", %{site: site} do
      assert {:error, :unknown_token} = Tokens.put(builder(), site.id, "--not-a-token", "#fff")
    end
  end

  # ONE BUILD PER EDIT, AND IT IS THE ROW'S. `put/4` writes the sheet and nothing else: saving it
  # queues the row's job (`SendToOban`), that job queues the site's CSS bundle, and the bundle job
  # builds and stores it (`TailwindCompiler.compile_and_store/1`). Quick edits share one bundle job,
  # since a site has one pending at a time. `SendToOban` does nothing under `env_test?`, so the flag
  # is off here.
  describe "the CSS a token reaches" do
    setup %{site: site} do
      Application.put_env(:mishka_cms_core, :env_test?, false)

      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: 0,
          active: true
        })

      on_exit(fn ->
        Application.put_env(:mishka_cms_core, :env_test?, true)
        SiteState.delete(site.id)
      end)
    end

    test "a site's first override queues its new sheet's job, active so the job builds it", %{
      site: site
    } do
      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#ff0000")

      assert [%{"action" => "create", "data" => sheet}] = sheet_jobs(site.id)
      assert sheet["active"]
      assert sheet["content"] =~ "--danger-light: #ff0000;"
    end

    test "an edit of the site's own sheet queues that sheet's job", %{site: site} do
      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#ff0000")
      [%{"data" => %{"id" => id}}] = sheet_jobs(site.id)
      @repo.delete_all(Oban.Job)

      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#00ff00")

      assert [%{"action" => "update", "data" => %{"id" => ^id} = sheet}] = sheet_jobs(site.id)
      assert sheet["content"] =~ "--danger-light: #00ff00;"
    end

    # A site admin writes as the site, so the row and its job carry that site.
    test "a site admin's writes queue their own site's jobs", %{site: site} do
      admin = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

      assert {:ok, _} = Tokens.put(admin, site.id, "--danger-light", "#ff0000")
      assert [%{"action" => "create", "data" => %{"active" => true}}] = sheet_jobs(site.id)
      @repo.delete_all(Oban.Job)

      assert {:ok, _} = Tokens.put(admin, site.id, "--danger-light", "#00ff00")
      assert [%{"action" => "update", "data" => sheet}] = sheet_jobs(site.id)
      assert sheet["content"] =~ "--danger-light: #00ff00;"
    end

    test "the sheet's job queues the site's CSS bundle", %{site: site} do
      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#ff0000")
      [job] = sheet_jobs(site.id)

      assert :ok = perform_job(RuntimeCompilerWorker, job)

      assert [_bundle] = bundle_jobs(site.name)
    end

    test "edits made before the bundle is built are one bundle job", %{site: site} do
      for value <- ~w(#ff0000 #00ff00 #0000ff) do
        assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", value)
        Enum.each(sheet_jobs(site.id), &perform_job(RuntimeCompilerWorker, &1))
      end

      assert [_bundle] = bundle_jobs(site.name)
    end

    # The shared sheet is the start of every site's CSS, so its job drops that start and queues
    # every active site's bundle.
    test "a master's edit of the shared sheet queues every active site's bundle", %{site: site} do
      other = create_site!(name: "tokens-other", host: "other.tokens.local", active: true)

      :ok =
        SiteState.save(%{
          id: other.id,
          name: other.name,
          host: other.host,
          priority: 0,
          active: true
        })

      on_exit(fn -> SiteState.delete(other.id) end)

      :ok =
        AssetsState.save(%{
          id: "__shared_base__",
          type: "css",
          value: ".old{}",
          hash: "old",
          updated_at: DateTime.utc_now()
        })

      on_exit(fn -> AssetsState.delete("__shared_base__", "css") end)

      assert {:ok, _} = Tokens.put(builder(), nil, "--danger-light", "#ff0000")
      assert [%{"data" => %{"site_id" => nil}} = job] = sheet_jobs(nil)

      assert :ok = perform_job(RuntimeCompilerWorker, job)

      refute AssetsState.exists?("__shared_base__", "css")
      assert [_bundle] = bundle_jobs(site.name)
      assert [_bundle] = bundle_jobs(other.name)
    end

    @tag :integration
    test "and the bundle it builds is stored with the new value, and announced", %{site: site} do
      TailwindCompiler.ensure_installed()
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, "site:#{site.name}:assets")

      # The bundle builds the shared base too, out of this test's rows, which roll back.
      on_exit(fn ->
        for id <- [site.name, "__shared_base__"],
            type <- ~w(css brotli_css gzip_css),
            do: AssetsState.delete(id, type)
      end)

      assert {:ok, _} = Tokens.put(builder(), site.id, "--danger-light", "#13579b")
      Enum.each(sheet_jobs(site.id), &perform_job(RuntimeCompilerWorker, &1))
      [bundle] = bundle_jobs(site.name)

      assert {:ok, _css} = perform_job(RuntimeCompilerWorker, bundle)

      assert AssetsState.get_value(site.name, "css") =~ ~r/--danger-light:\s*#13579b/
      assert AssetsState.get_value(site.name, "brotli_css")
      assert_received {:css_updated, _hash}
    end
  end

  describe "declarations/1" do
    test "reads name and value pairs in source order" do
      assert Tokens.declarations(":root{--a: 1px; --b: red;}") == [{"--a", "1px"}, {"--b", "red"}]
    end

    test "anything that is not a declaration contributes nothing" do
      assert Tokens.declarations("") == []
      assert Tokens.declarations(nil) == []
      assert Tokens.declarations(".foo { color: red; }") == []
    end
  end

  defp reload(sheet) do
    MishkaCmsCore.Runtime.Stylesheet
    |> Ash.get!(sheet.id, authorize?: false)
  end

  defp value_of(tokens, key), do: tokens |> Enum.find(&(&1.key == key)) |> Map.get(:value)

  defp sheet_jobs(site_id) do
    for %{args: %{"resource" => "MishkaCmsCore.Runtime.Stylesheet", "data" => sheet} = args} <-
          all_enqueued(worker: RuntimeCompilerWorker),
        sheet["site_id"] == site_id,
        do: args
  end

  defp bundle_jobs(site_name) do
    for %{args: %{"data" => %{"site_name" => ^site_name, "type" => "css"}} = args} <-
          all_enqueued(worker: RuntimeCompilerWorker),
        do: args
  end

  defp sheet_count(site_id) do
    MishkaCmsCore.Runtime.Stylesheet
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.read!(page: false)
    |> length()
  end
end
