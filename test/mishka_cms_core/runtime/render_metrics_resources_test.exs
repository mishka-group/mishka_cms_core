defmodule MishkaCmsCore.Runtime.RenderMetricsResourcesTest.Busy do
  @moduledoc false
  # Burns exactly `us` microseconds of wall time, so every expected number is known.
  def spin(us) do
    deadline = System.monotonic_time(:microsecond) + us
    loop(deadline)
    us
  end

  defp loop(deadline) do
    if System.monotonic_time(:microsecond) < deadline, do: loop(deadline), else: :ok
  end
end

defmodule MishkaCmsCore.Runtime.RenderMetricsResourcesTest do
  # Pages, layouts, error pages, stylesheets and JS hooks on the Performance Metrics card. The
  # component's own cases are in `MishkaCmsCore.Runtime.RenderMetricsTest`.
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.{RenderMetrics, Translations}
  alias MishkaCmsCore.Runtime.Compilers.ErrorCompiler
  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Test.RuntimePageHostLive
  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers

  @moduletag :integration
  @endpoint MishkaCmsCore.TestEndpoint
  @spin "MishkaCmsCore.Runtime.RenderMetricsResourcesTest.Busy.spin"
  @switch "runtime.render_metrics"

  # A TEST NODE LOADS EACH MODULE FROM DISK ON ITS FIRST CALL, which adds about a millisecond to the
  # first render that reaches it; a release preloads every module at boot. Loaded here once, so a
  # single render measures the template and not the code loader.
  setup_all do
    for app <- [:phoenix_live_view, :phoenix_html, :mishka_cms_core],
        module <- Application.spec(app, :modules) || [],
        do: Code.ensure_loaded(module)

    :ok
  end

  setup do
    :ok = SettingsState.put(nil, @switch, %{"value" => true})
    on_exit(fn -> SettingsState.delete(nil, @switch) end)

    n = System.unique_integer([:positive])
    site = create_site!(name: "rmr-#{n}", host: "rmr-#{n}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> SiteState.delete(site.id) end)
    :ok = Translations.put_site(site.id)
    {:ok, site: site, n: n}
  end

  # The spin's deadline is in whole µs, so a run can land a µs or two short of it; the ceiling
  # leaves room for HEEx's own work and a busy machine.
  defp about?(measured, expected),
    do: measured >= expected - 10 and measured <= expected * 1.5 + 500

  defp component!(site, name, template, extra \\ []) do
    c =
      create_component!(
        [
          name: name,
          template: template,
          active: true,
          precompile: false,
          site_id: site.id
        ] ++ extra
      )

    :ok = SiteState.put_component(site.id, c.name)
    on_exit(fn -> SiteState.delete_component(site.id, c.name) end)
    c
  end

  defp page!(site, template) do
    page =
      create_page!(
        site_id: site.id,
        path: "/rmr-#{System.unique_integer([:positive])}",
        template: template,
        active: true,
        precompile: false
      )

    module = CompilerHelpers.module_name(page.id, site.name, "Page")

    {:ok, ^module} =
      ModuleCompilerHandler.compile_or_return_module(module, page.path, site.name, site.id)

    {page, module}
  end

  defp layout!(site, template) do
    layout =
      create_layout!(
        site_id: site.id,
        name: "rmr-layout-#{System.unique_integer([:positive])}",
        path: "/rmr-layout-#{System.unique_integer([:positive])}",
        template: template
      )

    module = CompilerHelpers.module_name(layout.id, site.name, "Layout")

    {:ok, ^module} =
      ModuleCompilerHandler.compile_or_return_module(module, layout.path, site.name, site.id)

    module
  end

  # What LiveView does: the page is rendered, then handed to the layout as `@inner_content`.
  defp draw_in_layout(layout_module, page_module) do
    assigns = %{__changed__: nil, flash: %{}}
    page = page_module.render(assigns)

    assigns
    |> Map.put(:inner_content, page)
    |> layout_module.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp mount_page(module, site) do
    session = %{"page_module" => Atom.to_string(module), "site_id" => site.id}

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), RuntimePageHostLive, session: session)

    view
  end

  defp card(resource, record, metrics) do
    preview =
      PreviewHelpers.empty()
      |> Map.merge(%{
        resource: resource,
        record: record,
        active_tab: "overview",
        metrics: metrics
      })

    render_component(&RuntimePreviewModal.modal/1, preview: preview)
  end

  defp box(html, id),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query("##{id}") |> LazyHTML.text()

  defp record(resource, attrs),
    do:
      struct(
        resource,
        [
          id: "rec-1",
          name: "probe",
          site: %{name: "Global"},
          active: true,
          inserted_at: ~U[2026-01-01 10:00:00Z],
          updated_at: ~U[2026-01-02 10:00:00Z]
        ] ++ attrs
      )

  describe "pages" do
    test "a page's time is its server render, holding the components it draws", %{
      site: site,
      n: n
    } do
      inner = component!(site, "rmr-inner-#{n}", ~s|<b>{#{@spin}(400)}</b>|)

      {_page, module} =
        page!(
          site,
          ~s|<div>{#{@spin}(600)}<.component component_name="#{inner.name}" site="#{site.name}" /></div>|
        )

      inner_module = CompilerHelpers.module_name(inner.name, site.name, "Component")
      refute CompilerHelpers.loaded?(inner_module), "the component is built while the page draws"

      _view = mount_page(module, site)

      # the HTTP render and the connected one; the component's build is in neither
      assert %{full: %{count: 2, avg_us: page_us}} = RenderMetrics.stats(module)
      assert about?(page_us, 1000)
      assert %{full: %{count: 2, avg_us: inner_us}} = RenderMetrics.stats(inner_module)
      assert about?(inner_us, 400)
    end

    test "a draft preview's module is built with no clock" do
      refute RenderMetrics.measured?(MishkaCmsCore.Runtime.Preview.Abc123.Page)
      assert RenderMetrics.measured?(CompilerHelpers.module_name("id", "site", "Page"))
      assert RenderMetrics.measured?(CompilerHelpers.module_name("id", "site", "Component"))
      refute RenderMetrics.measured?(CompilerHelpers.module_name("id", "site", "Sitemap"))
    end

    test "the card shows a page's numbers like a component's" do
      metrics = %{
        on?: true,
        loaded?: true,
        stats: %{full: %{count: 4, avg_us: 2400}, update: %{count: 3, avg_us: 300}},
        build: %{us: 9_000, cache: :off, at: ~U[2026-10-28 12:00:00Z]}
      }

      html =
        card(MishkaCmsCore.Runtime.Page, record(MishkaCmsCore.Runtime.Page, path: "/x"), metrics)

      assert box(html, "runtime-preview-render-time") =~ "2.4 ms"
      assert box(html, "runtime-preview-render-time") =~ "Average of 4 full renders"
      assert box(html, "runtime-preview-cache") =~ "Compiled in 9.0 ms"
      assert box(html, "runtime-preview-rerenders") =~ "3"
      assert html =~ "File Size"
      assert html =~ "this server, since its last build"
      refute html =~ "1.2s"
    end
  end

  describe "layouts" do
    test "a layout's time is its own: the page it draws as @inner_content is not counted", %{
      site: site
    } do
      {_page, page_module} = page!(site, ~s|<p class="the-page">{#{@spin}(600)}</p>|)

      layout_module =
        layout!(site, ~s|<div>{#{@spin}(300)}<main :if={true}>{@inner_content}</main></div>|)

      assert draw_in_layout(layout_module, page_module) =~ "the-page"

      assert %{full: %{count: 1, avg_us: layout_us}} = RenderMetrics.stats(layout_module)
      assert about?(layout_us, 300)
      assert %{full: %{count: 1, avg_us: page_us}} = RenderMetrics.stats(page_module)
      assert about?(page_us, 600)
    end

    test "a component that draws @inner_content in its slot does not count the page either", %{
      site: site,
      n: n
    } do
      wrap =
        component!(
          site,
          "rmr-wrap-#{n}",
          ~s|<section>{#{@spin}(200)}{render_slot(@inner_block)}</section>|,
          slots: [%{"name" => "inner_block", "opts" => %{}}]
        )

      {_page, page_module} = page!(site, ~s|<p class="the-page">{#{@spin}(600)}</p>|)

      layout_module =
        layout!(
          site,
          ~s|<div>{#{@spin}(300)}<.component component_name="#{wrap.name}" site="#{site.name}">{@inner_content}</.component></div>|
        )

      assert draw_in_layout(layout_module, page_module) =~ "the-page"

      wrap_module = CompilerHelpers.module_name(wrap.name, site.name, "Component")
      assert %{full: %{avg_us: wrap_us}} = RenderMetrics.stats(wrap_module)
      assert about?(wrap_us, 200)
      assert %{full: %{avg_us: layout_us}} = RenderMetrics.stats(layout_module)
      assert about?(layout_us, 500), "the layout holds its component, not the page"
      assert %{full: %{avg_us: page_us}} = RenderMetrics.stats(page_module)
      assert about?(page_us, 600)
    end

    test "the card says a layout's re-renders are its page's updates" do
      metrics = %{
        on?: true,
        loaded?: true,
        stats: %{full: %{count: 2, avg_us: 800}, update: %{count: 6, avg_us: 90}},
        build: nil
      }

      html =
        card(
          MishkaCmsCore.Runtime.Layout,
          record(MishkaCmsCore.Runtime.Layout, path: "/l"),
          metrics
        )

      assert box(html, "runtime-preview-render-time") =~ "800 µs"
      rerenders = box(html, "runtime-preview-rerenders")
      assert rerenders =~ "6"
      assert rerenders =~ "With every update of the page inside it, 90 µs each"
    end
  end

  describe "error pages" do
    defp error_page!(site, n, attrs) do
      error =
        create_error_page!([site_id: site.id, name: "rmr-e-#{n}", path: "/rmr-e-#{n}"] ++ attrs)

      module = CompilerHelpers.module_name(error.id, site.name, "ErrorPage")

      {:ok, ^module} =
        ModuleCompilerHandler.compile_or_return_module(module, error.path, site.name, site.id)

      module
    end

    defp show(module, status),
      do:
        module
        |> ErrorCompiler.render_page(Phoenix.ConnTest.build_conn(), status)
        |> IO.iodata_to_binary()

    test "an error page is counted per status, drawn whole by its EEx root layout", %{
      site: site,
      n: n
    } do
      # the factory's root layout is EEx, so the page answers `{:safe, iodata}`: all of it in the call
      module =
        error_page!(site, n,
          error_pages: [
            %{status: 404, template: ~s|<h1>{#{@spin}(300)}</h1>|},
            %{status: 500, template: ~s|<h1>{#{@spin}(100)}</h1>|}
          ]
        )

      assert show(module, 404) =~ "300"
      show(module, 404)
      show(module, 500)

      assert %{full: %{count: 2, avg_us: us_404}} = RenderMetrics.stats({module, 404})
      assert about?(us_404, 300)
      assert %{full: %{count: 1, avg_us: us_500}} = RenderMetrics.stats({module, 500})
      assert about?(us_500, 100)

      # a new build starts its counts again, every status of it
      RenderMetrics.handle_build(
        [:mishka_cms, :runtime, :compilers, :module, :stop],
        %{duration: 1},
        %{module: module, cache: :off},
        nil
      )

      assert RenderMetrics.stats({module, 404}) == nil
      assert RenderMetrics.stats({module, 500}) == nil
    end

    test "with a HEEx root the page is drawn after the call and still timed", %{site: site, n: n} do
      module =
        error_page!(site, n,
          root_layout_template: nil,
          error_pages: [%{status: 404, template: ~s|<h1>{#{@spin}(300)}</h1>|}]
        )

      # the first draw of a HEEx root fills what it caches; the second is the template's own time
      assert show(module, 404) =~ "300"
      %{full: %{count: 1, avg_us: first}} = RenderMetrics.stats({module, 404})
      show(module, 404)
      assert %{full: %{count: 2, avg_us: avg}} = RenderMetrics.stats({module, 404})
      assert about?(avg * 2 - first, 300)
    end

    test "the card's fourth box is how often it was shown, per status" do
      metrics = %{
        on?: true,
        loaded?: true,
        stats: %{
          full: %{count: 39, avg_us: 1015},
          update: %{count: 0, avg_us: 0},
          statuses: [{404, %{count: 37, avg_us: 800}}, {500, %{count: 2, avg_us: 1100}}]
        },
        build: nil
      }

      html =
        card(
          MishkaCmsCore.Runtime.ErrorPage,
          record(MishkaCmsCore.Runtime.ErrorPage, path: "/e"),
          metrics
        )

      shown = box(html, "runtime-preview-rerenders")
      assert shown =~ "Shown"
      assert shown =~ "39"
      assert shown =~ "404 800 µs ×37 · 500 1.1 ms ×2"
      assert box(html, "runtime-preview-render-time") =~ "1.0 ms"
    end
  end

  describe "stylesheets" do
    @built %{
      kind: :asset,
      type: "css",
      bundle: "rmr-site",
      sizes: %{raw: 184_320, brotli: 31_744, gzip: 39_936},
      hash: "a1b2c3d4e5f6a7b8",
      updated_at: ~U[2026-10-28 12:00:00Z],
      state: :live,
      took_ms: 1_240
    }

    defp sheet_card(metrics),
      do:
        card(
          MishkaCmsCore.Runtime.Stylesheet,
          record(MishkaCmsCore.Runtime.Stylesheet, kind: :custom),
          metrics
        )

    test "the card is about the bundle it is built into, as visitors download it" do
      html = sheet_card(@built)
      bundle = box(html, "runtime-preview-bundle")
      assert bundle =~ "Site CSS"
      assert bundle =~ "31.0 KB"
      assert bundle =~ "raw 180.0 KB · gzip 39.0 KB"
      build = box(html, "runtime-preview-build")
      assert build =~ "Built"
      assert build =~ "Last rebuild took 1.2 s"
      last = box(html, "runtime-preview-last-built")
      assert last =~ "2026-10-28 12:00"
      assert last =~ "Version a1b2c3d4"
      assert html =~ "this server"
      refute html =~ "since its last build"
      refute html =~ "1.2s"
    end

    test "a global stylesheet seen by a master is the shared base" do
      bundle = box(sheet_card(%{@built | bundle: "__shared_base__"}), "runtime-preview-bundle")
      assert bundle =~ "Shared CSS"
      assert bundle =~ "the start of every site's CSS"
    end

    test "says when it is not built, or building" do
      html = sheet_card(%{@built | sizes: nil, hash: nil, updated_at: nil, took_ms: nil})
      assert box(html, "runtime-preview-bundle") =~ "Not built on this server"
      assert box(html, "runtime-preview-build") =~ "Not built"
      assert box(html, "runtime-preview-last-built") =~ "—"

      assert box(sheet_card(%{@built | state: :compiling}), "runtime-preview-build") =~
               "Building…"

      assert box(sheet_card(:loading), "runtime-preview-bundle") =~ "Loading…"
    end
  end
end
