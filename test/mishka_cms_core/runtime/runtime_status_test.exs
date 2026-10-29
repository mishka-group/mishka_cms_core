# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.RuntimeStatusTest do
  @moduledoc """
  What the runtime-status panel says about a record — and specifically what it says about one whose
  code will not compile, which until now was anything but that.

  `CompileFailureState` has always recorded the reason so the hot path can skip recompiling a
  known-broken module on every request. Nothing else read it, so a page with broken code reported
  `Live` when an older version of its module happened to still be loaded, and
  `Ready — compiles on first request` when it was not. Both are true about the runtime. Neither is
  what the author needed to know.
  """
  use MishkaCmsCore.DataCase

  import Ecto.Query

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.RuntimeStatus
  alias MishkaCmsCore.Runtime.States.CompileFailureState

  setup do
    site = create_site!()
    page = create_page!(site_id: site.id)
    module = MishkaCmsCore.Runtime.Compilers.Helpers.module_name(page.id, "Global", "Page")

    on_exit(fn -> CompileFailureState.clear(module) end)

    %{page: page, module: module}
  end

  describe "a record whose code will not compile" do
    test "reports the failure and the reason", %{page: page, module: module} do
      CompileFailureState.record(module, {:compilation_error, "undefined function shout/1"})

      status = RuntimeStatus.compute(page, Page)

      assert status.state == :failed
      assert status.label == "Compile failed"
      assert status.message =~ "undefined function shout/1"
    end

    # A page that will not compile but whose module is still loaded keeps serving the last version
    # that did — the old code is only purged on the success branch. That is right for a visitor and
    # a trap for an author, whose change is not on the page and who was told nothing.
    test "says so when a stale version is still being served", %{page: page, module: module} do
      Code.compile_quoted(quote(do: defmodule(unquote(module), do: def(render(_), do: :stale))))
      on_exit(fn -> :code.purge(module) && :code.delete(module) end)

      CompileFailureState.record(module, {:compilation_error, "boom"})

      status = RuntimeStatus.compute(page, Page)

      assert status.artifact_loaded?, "the previous version is still in RAM"
      assert status.state == :failed
      assert status.message =~ "Still serving the last version that compiled"
      assert status.message =~ "boom"
    end

    test "and does not say so when nothing is being served", %{page: page, module: module} do
      CompileFailureState.record(module, {:compilation_error, "boom"})

      status = RuntimeStatus.compute(page, Page)

      refute status.artifact_loaded?
      refute status.message =~ "Still serving"
      assert status.message =~ "boom"
    end

    test "a reason with no message still reads as a sentence", %{page: page, module: module} do
      CompileFailureState.record(module, :compilation_error)

      assert RuntimeStatus.compute(page, Page).message =~ "did not compile"
    end
  end

  describe "a record that is fine" do
    test "a lazy page is still reported as ready rather than failed", %{page: page} do
      status = RuntimeStatus.compute(page, Page)

      assert status.state == :lazy_ready
      assert status.message =~ "first visitor request"
    end

    test "clearing the failure restores the ordinary answer", %{page: page, module: module} do
      CompileFailureState.record(module, {:compilation_error, "boom"})
      assert RuntimeStatus.compute(page, Page).state == :failed

      CompileFailureState.clear(module)
      assert RuntimeStatus.compute(page, Page).state == :lazy_ready
    end

    # An archived or inactive record is answered before the compile state is consulted: it is not
    # compiled because nobody asked for it to be, which is not a failure.
    test "archived and inactive still win", %{page: page, module: module} do
      CompileFailureState.record(module, {:compilation_error, "boom"})

      assert RuntimeStatus.compute(%{page | active: false}, Page).state == :inactive

      assert RuntimeStatus.compute(%{page | archived_at: DateTime.utc_now()}, Page).state ==
               :archived
    end
  end

  describe "a component reads its precompile flag like everything else" do
    # It used to be the exception — the panel was told a component had no such flag, because every
    # active one was compiled at boot regardless. Now the flag means on a component exactly what it
    # means on a page, and the panel has to say so or an author reads "Pending compile" forever on a
    # component that is behaving correctly.
    test "a lazy component reports ready, not pending" do
      site = create_site!()
      component = create_component!(site_id: site.id, precompile: false)

      status = RuntimeStatus.compute(component, MishkaCmsCore.Runtime.Component)

      assert status.mode == :lazy
      assert status.state == :lazy_ready
    end

    test "a precompiled component that has not compiled yet is genuinely pending" do
      site = create_site!()
      component = create_component!(site_id: site.id, precompile: true)

      status = RuntimeStatus.compute(component, MishkaCmsCore.Runtime.Component)

      assert status.mode == :eager_precompile
      assert status.state == :pending
    end
  end

  describe "an asset-backed record" do
    # A JS hook has no module of its own, so the compile-failure branch must not swallow it — this
    # is the case that needed the classifier's config kept threaded through.
    test "is still classified by its bundle" do
      site = create_site!(name: "assets-#{System.unique_integer([:positive])}")
      hook = create_js_hook!(site_id: site.id)

      status = RuntimeStatus.compute(hook, MishkaCmsCore.Runtime.JsHook)

      assert status.module == nil
      assert status.state in [:live, :pending]
      assert status.message =~ "js bundle"
    end
  end

  # THE ROW'S OWN JOB SUCCEEDS EITHER WAY. A stylesheet or hook row only queues its bundle, so its
  # status said `Live` while the bundle's build failed and the site went on serving the last one.
  describe "an asset-backed record whose bundle did not build" do
    setup do
      site = create_site!(name: "abf-status-#{System.unique_integer([:positive])}")

      on_exit(fn ->
        Enum.each([site.name, "abf-status-other"], &Helpers.forget_asset_builds/1)
      end)

      %{site: site}
    end

    test "says so, with the reason, and that the last bundle is still served", %{site: site} do
      hook = [site_id: site.id] |> create_js_hook!() |> Ash.load!(:site, authorize?: false)

      :ok =
        Helpers.record_asset_build(site.name, "js", {:error, "Could not resolve x", :last_good})

      status = RuntimeStatus.compute(hook, MishkaCmsCore.Runtime.JsHook)

      assert status.state == :failed
      assert status.label == "Bundle build failed"
      assert status.message =~ "The js bundle of #{site.name} did not build."
      assert status.message =~ "Still serving the last one that built."
      assert status.message =~ "Could not resolve x"
    end

    test "does not claim a last bundle when there was none to keep", %{site: site} do
      hook = [site_id: site.id] |> create_js_hook!() |> Ash.load!(:site, authorize?: false)
      :ok = Helpers.record_asset_build(site.name, "js", {:error, "broke", :nothing})

      status = RuntimeStatus.compute(hook, MishkaCmsCore.Runtime.JsHook)

      assert status.state == :failed
      refute status.message =~ "Still serving"
    end

    test "a site's row hears only its own bundle", %{site: site} do
      hook = [site_id: site.id] |> create_js_hook!() |> Ash.load!(:site, authorize?: false)
      :ok = Helpers.record_asset_build("abf-status-other", "js", {:error, "theirs", :last_good})

      assert RuntimeStatus.compute(hook, MishkaCmsCore.Runtime.JsHook).state in [:live, :pending]
    end

    # A global row is in the shared base and in every site's bundle, so any of them failing is its.
    test "a global row hears every bundle", %{site: site} do
      {:ok, sheet} =
        MishkaCmsCore.Runtime.Stylesheet
        |> Ash.Changeset.for_create(
          :master_create,
          %{
            name: "abf-global-#{System.unique_integer([:positive])}",
            kind: :custom,
            content: ".a{}",
            site_id: nil,
            active: true
          },
          authorize?: false
        )
        |> Ash.create()

      :ok = Helpers.record_asset_build(site.name, "css", {:error, "one", :last_good})
      :ok = Helpers.record_asset_build("abf-status-other", "css", {:error, "two", :last_good})

      status = RuntimeStatus.compute(sheet, MishkaCmsCore.Runtime.Stylesheet)

      assert status.state == :failed
      assert status.message =~ site.name
      assert status.message =~ "abf-status-other"
      assert status.message =~ "one; two"
    end
  end

  describe "a compile job from before this node booted" do
    defp job!(page, state, inserted_at) do
      {:ok, job} =
        %{"resource" => inspect(Page), "data" => %{"id" => page.id}}
        |> MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker.new(queue: :modules)
        |> Oban.insert()

      {1, _} =
        Oban.Repo.update_all(
          Oban.config(),
          from(j in Oban.Job, where: j.id == ^job.id),
          set: [state: state, inserted_at: inserted_at, attempted_at: inserted_at]
        )
    end

    @before_boot ~U[2020-01-01 00:00:00.000000Z]

    # A restart stops the node mid-job and the boot cancels what is left, then compiles from the
    # database without a job — the page compiled and served while its status said `Compiling…` or
    # `Compile cancelled`.
    test "is not read as compiling", %{page: page} do
      job!(page, "executing", @before_boot)

      status = RuntimeStatus.compute(page, Page)

      assert status.state == :lazy_ready
      assert status.job == nil
    end

    test "is not read as failed when the boot cancelled it", %{page: page} do
      job!(page, "cancelled", @before_boot)

      assert RuntimeStatus.compute(page, Page).state == :lazy_ready
    end

    test "while one since the boot still decides it", %{page: page} do
      job!(page, "executing", DateTime.utc_now())
      assert RuntimeStatus.compute(page, Page).state == :compiling

      job!(page, "cancelled", DateTime.utc_now())
      assert %{state: :failed, label: "Compile cancelled"} = RuntimeStatus.compute(page, Page)
    end
  end
end
