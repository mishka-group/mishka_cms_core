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
end
