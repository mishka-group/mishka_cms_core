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

  defp component!(site, name, template) do
    c =
      create_component!(
        name: name,
        template: template,
        active: true,
        precompile: false,
        site_id: site.id
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
end
