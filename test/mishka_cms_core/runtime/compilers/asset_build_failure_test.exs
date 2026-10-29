# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.AssetBuildFailureTest do
  @moduledoc """
  A CSS bundle build that fails: the bundle it would have replaced stays, and the failure is recorded
  so the editor and the Stylesheets page can say the latest change is not live.

  The record lives in `CompileFailureState` beside the modules that did not compile
  (`Helpers.record_asset_build/3`). The Tailwind half breaks the shared base the way a real install
  can: a global `:custom` row whose `@apply` names a utility that does not exist. Saves do not run
  Tailwind, so such a row can be written, and it fails only the shared base, which every site's CSS
  starts with.

  `async: false` — `AssetsState`, `SiteState` and `CompileFailureState` are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  import ExUnit.CaptureLog

  alias MishkaCmsCore.Runtime.Compilers.{Helpers, TailwindCompiler}
  alias MishkaCmsCore.Runtime.Handlers.{BootHandler, SiteRuntime}
  alias MishkaCmsCore.Runtime.Resources.Changes.SendToOban
  alias MishkaCmsCore.Runtime.States.{AssetsState, SiteState}
  alias MishkaCmsCore.Runtime.Stylesheet

  @shared "__shared_base__"

  defp clear_bundle(id),
    do: for(type <- ~w(css brotli_css gzip_css), do: AssetsState.delete(id, type))

  describe "the build record" do
    setup do
      on_exit(fn -> Enum.each(["rec-site", "rec-other"], &Helpers.forget_asset_builds/1) end)
    end

    test "keeps a failure until a build works, and announces each change once" do
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, Helpers.asset_builds_topic("rec-site"))
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, Helpers.asset_builds_topic(:all))

      :ok = Helpers.record_asset_build("rec-site", "css", {:error, "boom", :last_good})

      assert Helpers.asset_build_failure("rec-site", "css") == %{
               reason: "boom",
               served: :last_good
             }

      assert_received {:asset_build, "rec-site", "css"}
      assert_received {:asset_build, "rec-site", "css"}, "the :all topic was not told"

      :ok = Helpers.record_asset_build("rec-site", "css", {:error, "boom", :last_good})
      refute_received {:asset_build, _bundle, _type}, "an unchanged failure was announced again"

      :ok = Helpers.record_asset_build("rec-site", "css", :ok)
      assert Helpers.asset_build_failure("rec-site", "css") == nil
      assert_received {:asset_build, "rec-site", "css"}
      assert_received {:asset_build, "rec-site", "css"}

      :ok = Helpers.record_asset_build("rec-site", "css", :ok)

      refute_received {:asset_build, "rec-site", "css"},
                      "a build that changed nothing was announced"
    end

    test "keeps CSS and JS apart, lists them by bundle, and turns a term into text" do
      :ok = Helpers.record_asset_build("rec-site", "css", {:error, "css broke", :nothing})
      :ok = Helpers.record_asset_build("rec-other", "css", {:error, {:exit, 1}, :last_good})
      :ok = Helpers.record_asset_build("rec-site", "js", {:error, "js broke", :last_good})

      assert [{"rec-other", %{reason: "{:exit, 1}"}}, {"rec-site", %{reason: "css broke"}}] =
               Helpers.asset_build_failures("css")

      assert [{"rec-site", %{reason: "js broke"}}] = Helpers.asset_build_failures("js")
    end

    test "is forgotten with the site's bundles when the site is purged, and says so" do
      :ok = Helpers.record_asset_build("rec-site", "css", {:error, "css broke", :last_good})
      :ok = Helpers.record_asset_build("rec-site", "js", {:error, "js broke", :last_good})
      Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, Helpers.asset_builds_topic("rec-site"))

      SiteRuntime.purge_parts("rec-site", [], false)

      assert_received {:asset_build, "rec-site", "css"}
      assert_received {:asset_build, "rec-site", "js"}

      assert Helpers.asset_build_failure("rec-site", "css") == nil
      assert Helpers.asset_build_failure("rec-site", "js") == nil
    end
  end

  describe "a CSS build that fails" do
    @describetag :integration

    setup do
      TailwindCompiler.ensure_installed()
      n = System.unique_integer([:positive])
      site = create_site!(name: "abf-#{n}", host: "abf-#{n}.test", active: true)

      :ok =
        SiteState.save(%{
          id: site.id,
          name: site.name,
          host: site.host,
          priority: 0,
          active: true
        })

      on_exit(fn ->
        SiteState.delete(site.id)
        clear_bundle(site.name)
        clear_bundle(@shared)
        Helpers.forget_asset_builds(site.name)
        Helpers.forget_asset_builds(@shared)
      end)

      %{site: site}
    end

    defp break_the_shared_base! do
      Stylesheet
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: "abf-broken-#{System.unique_integer([:positive])}",
          kind: :custom,
          content: ".abf-broken { @apply rounde-xl; }",
          site_id: nil,
          active: true
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    test "a broken shared base is rebuilt in place, so every site keeps the last one that built" do
      {:ok, good} = TailwindCompiler.compile_and_store_shared_base()
      break_the_shared_base!()

      capture_log(fn ->
        assert {:error, _reason} = TailwindCompiler.compile_and_store_shared_base()
      end)

      assert AssetsState.get_value(@shared, "css") == good
      assert %{served: :last_good, reason: reason} = Helpers.asset_build_failure(@shared, "css")
      assert reason =~ "rounde-xl"
    end

    test "a site whose shared base will not build keeps the bundle it had", %{site: site} do
      {:ok, good} = TailwindCompiler.compile_and_store(site.name)
      break_the_shared_base!()
      clear_bundle(@shared)

      capture_log(fn ->
        assert {:error, reason} = TailwindCompiler.compile_and_store(site.name)
        assert reason =~ "shared CSS"
      end)

      assert AssetsState.get_value(site.name, "css") == good,
             "the broken build replaced the bundle"

      assert %{served: :last_good, reason: reason} = Helpers.asset_build_failure(site.name, "css")
      assert reason =~ "rounde-xl"
    end

    # A RESTART STARTS WITH NOTHING TO KEEP. `AssetsState` is in memory, so a site's first build after
    # a boot has no last good bundle; it gets the partial one rather than none at all, and is told.
    test "a site with no bundle yet gets the partial one, and the failure is recorded", %{
      site: site
    } do
      break_the_shared_base!()
      clear_bundle(@shared)

      capture_log(fn -> assert {:ok, _css} = TailwindCompiler.compile_and_store(site.name) end)

      assert AssetsState.exists?(site.name, "css")
      assert %{served: :partial} = Helpers.asset_build_failure(site.name, "css")
      assert %{served: :nothing} = Helpers.asset_build_failure(@shared, "css")
    end

    # A PARTIAL BUNDLE IS NOT ONE TO KEEP. Refusing to store over it would leave every later edit of
    # the site off the page until the global row is fixed, under a message saying the last good
    # bundle is still served.
    test "a partial bundle does not hold up the site's next build", %{site: site} do
      break_the_shared_base!()
      clear_bundle(@shared)
      capture_log(fn -> assert {:ok, _css} = TailwindCompiler.compile_and_store(site.name) end)
      first = AssetsState.hash(site.name, "css")

      template = ~s(<p class="pt-[47px]">later</p>)
      page = create_page!(site_id: site.id, template: template)
      BootHandler.create_template_file(site.name, "page", page.name, template)
      on_exit(fn -> BootHandler.delete_template_file(site.name, "page", page.name) end)

      capture_log(fn -> assert {:ok, _css} = TailwindCompiler.compile_and_store(site.name) end)

      assert AssetsState.hash(site.name, "css") != first, "the site's later change was refused"
      assert AssetsState.get_value(site.name, "css") =~ "pt-\\[47px\\]"
      assert %{served: :partial} = Helpers.asset_build_failure(site.name, "css")
    end

    test "once the shared base builds again, the site's bundle is whole", %{site: site} do
      broken = break_the_shared_base!()
      clear_bundle(@shared)
      capture_log(fn -> TailwindCompiler.compile_and_store(site.name) end)

      Ash.destroy!(broken, action: :master_destroy, authorize?: false)
      clear_bundle(@shared)

      assert {:ok, _css} = TailwindCompiler.compile_and_store(site.name)

      assert Helpers.asset_build_failure(site.name, "css") == nil
      assert Helpers.asset_build_failure(@shared, "css") == nil
    end

    # ONE BASE BUILD AT A TIME: two global saves close together could store the older base last.
    test "a shared base build waits for the one already running" do
      lock = {{TailwindCompiler, :shared_base}, self()}
      true = :global.set_lock(lock, [node()])

      task = Task.async(fn -> TailwindCompiler.compile_and_store_shared_base() end)
      assert Task.yield(task, 300) == nil, "the build did not wait for the lock"

      :global.del_lock(lock, [node()])
      assert {:ok, _css} = Task.await(task, 60_000)
    end

    # The shared base scans the global hooks' templates, so a global hook's job writes them first.
    test "a global hook's classes reach the shared base its job rebuilds" do
      Application.put_env(:mishka_cms_core, :env_test?, false)
      on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

      hook =
        create_js_hook!(
          content: ~s|export default { mounted() { this.el.classList.add("pt-[43px]") } }|
        )

      on_exit(fn -> BootHandler.delete_template_file(nil, "js_hook", hook.name) end)

      [job] =
        for %{
              args:
                %{"resource" => "MishkaCmsCore.Runtime.JsHook", "data" => %{"id" => id}} = args
            } <-
              all_enqueued(worker: MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker),
            id == hook.id,
            do: args

      assert :ok = perform_job(MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker, job)

      assert AssetsState.get_value(@shared, "css") =~ "pt-\\[43px\\]"
      _ = SendToOban
    end

    test "the next build that works forgets the failure", %{site: site} do
      :ok = Helpers.record_asset_build(site.name, "css", {:error, "earlier", :last_good})

      assert {:ok, _css} = TailwindCompiler.compile_and_store(site.name)

      assert Helpers.asset_build_failure(site.name, "css") == nil
    end
  end
end
