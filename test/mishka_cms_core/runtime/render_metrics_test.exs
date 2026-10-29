defmodule MishkaCmsCore.Runtime.RenderMetricsTest.Busy do
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

defmodule MishkaCmsCore.Runtime.RenderMetricsTest do
  use MishkaCmsCore.DataCase, async: false

  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.{Component, LiveViewHelpers, RenderMetrics, Translations}
  alias MishkaCmsCore.Runtime.Compilers.Helpers, as: CompilerHelpers
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimePreviewModal
  alias MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.PreviewHelpers

  @moduletag :integration
  @endpoint MishkaCmsCore.TestEndpoint
  @spin "MishkaCmsCore.Runtime.RenderMetricsTest.Busy.spin"

  defmodule Host do
    use Phoenix.LiveView
    alias MishkaCmsCore.Runtime.LiveViewHelpers

    def mount(_params, session, socket) do
      :ok = MishkaCmsCore.Runtime.Translations.put_site(session["site_id"])

      {:ok,
       assign(socket,
         site: session["site"],
         names: session["names"],
         title: "a",
         us: 2000,
         other: 0
       )}
    end

    def handle_info({:set, key, value}, socket), do: {:noreply, assign(socket, key, value)}

    def render(assigns) do
      ~H"""
      <div id="host">
        <LiveViewHelpers.component component_name={@names.work} site={@site} title={@title} us={@us} />
        <LiveViewHelpers.component component_name={@names.live} site={@site} id="live-1" us={1000} />
        <span id="other">{@other}</span>
      </div>
      """
    end
  end

  @switch "runtime.render_metrics"

  setup do
    :ok = SettingsState.put(nil, @switch, %{"value" => true})
    on_exit(fn -> SettingsState.delete(nil, @switch) end)
    n = System.unique_integer([:positive])
    site = create_site!(name: "metrics-#{n}", host: "metrics-#{n}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> SiteState.delete(site.id) end)
    :ok = Translations.put_site(site.id)

    # 500 µs in the body, `us` in the template and 2 × 250 µs in a :for: every place a component's
    # work can be is on the clock.
    work =
      component!(
        site,
        "work-#{n}",
        ~s|<div><p>{@title}</p><p>{#{@spin}(@us)}</p><i :for={_ <- 1..2}>{#{@spin}(250)}</i><b>{@from_body}</b></div>|,
        [attr("title", "string", nil), attr("us", "integer", 0)],
        body: ~s|Phoenix.Component.assign(assigns, :from_body, #{@spin}(500))|
      )

    live =
      component!(
        site,
        "live-#{n}",
        ~s|<div id={@id}><p>{#{@spin}(@us)}</p></div>|,
        [attr("us", "integer", 0)],
        stateful: true
      )

    {:ok, site: site, names: %{work: work, live: live}}
  end

  defp attr(name, type, default),
    do: %{"name" => name, "type" => type, "opts" => %{"default" => default}}

  defp component!(site, name, template, attrs, extra) do
    c =
      create_component!(
        [
          name: name,
          template: template,
          attrs: attrs,
          active: true,
          precompile: false,
          site_id: site.id
        ] ++ extra
      )

    :ok = SiteState.put_component(site.id, c.name)
    on_exit(fn -> SiteState.delete_component(site.id, c.name) end)
    c.name
  end

  defp module_of(name, site), do: CompilerHelpers.module_name(name, site.name, "Component")

  # The spin's deadline is in whole µs, so a run can land a µs or two short of it; the ceiling
  # leaves room for HEEx's own work and a busy machine.
  defp about?(measured, expected),
    do: measured >= expected - 10 and measured <= expected * 1.5 + 500

  test "a page's renders are timed per component: full renders and updates apart", %{
    site: site,
    names: names
  } do
    work = module_of(names.work, site)
    live = module_of(names.live, site)
    refute CompilerHelpers.loaded?(work), "lazy: nothing is built before the first render"

    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{"site" => site.name, "site_id" => site.id, "names" => names}
      )

    # The HTTP render and the connected one, both full. The lazy build that happened inside the
    # first one is not in the number (it takes milliseconds; the work is 3 ms).
    stats = RenderMetrics.stats(work)
    assert stats.full.count == 2
    assert stats.update.count == 0
    assert about?(stats.full.avg_us, 500 + 2000 + 500)

    # The build of each module is recorded, with the disk cache off (not configured in tests).
    assert %{cache: :off, us: built_us, at: %DateTime{}} = RenderMetrics.build(work)
    assert built_us > 0

    # A live component is timed through its compiled `render/1`.
    assert %{full: %{count: 2, avg_us: live_us}} = RenderMetrics.stats(live)
    assert about?(live_us, 1000)

    # An assign no component reads: nothing renders again.
    send(view.pid, {:set, :other, 1})
    _ = render(view)
    assert RenderMetrics.stats(work).update.count == 0

    # Only `title` changes: an update, and the expensive expressions are not run again.
    send(view.pid, {:set, :title, "b"})
    _ = render(view)
    assert %{update: %{count: 1, avg_us: title_us}} = RenderMetrics.stats(work)
    assert title_us < 2000
    assert RenderMetrics.stats(live).update.count == 0

    # `us` changes: the expression that reads it runs again, and costs it again.
    send(view.pid, {:set, :us, 3000})
    _ = render(view)
    assert %{update: %{count: 2}} = RenderMetrics.stats(work)
  end

  test "with the setting off, nothing is timed", %{site: site, names: names} do
    :ok = SettingsState.delete(nil, @switch)
    refute RenderMetrics.on?()

    %{component_name: names.work, site: site.name, title: "x", us: 10, __changed__: nil}
    |> LiveViewHelpers.component()
    |> Phoenix.HTML.Safe.to_iodata()

    assert RenderMetrics.stats(module_of(names.work, site)) == nil

    :ok = SettingsState.put(nil, @switch, %{"value" => true})
    assert RenderMetrics.on?()
  end

  test "an author's preview is not counted", %{site: site, names: names} do
    work = module_of(names.work, site)

    LiveViewHelpers.rendering_for(site.name, fn ->
      %{component_name: names.work, site: site.name, title: "x", us: 10, __changed__: nil}
      |> LiveViewHelpers.component()
      |> Phoenix.HTML.Safe.to_iodata()
    end)

    assert CompilerHelpers.loaded?(work)
    assert RenderMetrics.stats(work) == nil
  end

  test "a new build starts the counts again", %{site: site, names: names} do
    work = module_of(names.work, site)

    draw = fn ->
      LiveViewHelpers.component(%{
        component_name: names.work,
        site: site.name,
        title: "x",
        us: 10,
        __changed__: nil
      })
      |> Phoenix.HTML.Safe.to_iodata()
    end

    draw.()
    assert %{full: %{count: 1}} = RenderMetrics.stats(work)

    RenderMetrics.handle_build(
      [:mishka_cms, :runtime, :compilers, :module, :stop],
      %{duration: System.convert_time_unit(5, :millisecond, :native)},
      %{module: work, cache: :hit},
      nil
    )

    assert RenderMetrics.stats(work) == nil
    assert %{cache: :hit, us: 5000} = RenderMetrics.build(work)
  end

  test "a rebuild that fails records no build and keeps the numbers", %{
    site: site,
    names: names
  } do
    work = module_of(names.work, site)

    %{component_name: names.work, site: site.name, title: "x", us: 10, __changed__: nil}
    |> LiveViewHelpers.component()
    |> Phoenix.HTML.Safe.to_iodata()

    before = {RenderMetrics.stats(work), RenderMetrics.build(work)}
    assert {%{full: %{count: 1}}, %{}} = before

    broken =
      quote(do: defmodule(unquote(work), do: def(broken, do: unquote(Macro.var(:nope, nil)))))

    assert {:error, ^work, _} =
             MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(broken)

    assert {RenderMetrics.stats(work), RenderMetrics.build(work)} == before
  end

  test "a component built lazily inside another's render is not in the other's time", %{
    site: site
  } do
    n = System.unique_integer([:positive])
    child = component!(site, "child-#{n}", ~S|<i>child</i>|, [], [])

    parent =
      component!(
        site,
        "parent-#{n}",
        ~s|<div>{#{@spin}(500)}<.component component_name="#{child}" site={@site} /></div>|,
        [],
        []
      )

    refute CompilerHelpers.loaded?(module_of(child, site))
    me = self()

    :telemetry.attach(
      "lazy-child-#{n}",
      [:mishka_cms, :runtime, :handlers, :module_compiler, :stop],
      fn _, m, meta, _ -> send(me, {:built, meta, m.duration}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("lazy-child-#{n}") end)

    # the parent is built first, outside any clock, so only the child builds inside the parent's
    LiveViewHelpers.ensure_component_loaded(parent, site.name)

    %{component_name: parent, site: site.name, __changed__: nil}
    |> LiveViewHelpers.component()
    |> Phoenix.HTML.Safe.to_iodata()

    assert CompilerHelpers.loaded?(module_of(child, site)),
           "the child was built inside the render"

    assert_received {:built, _meta, native}
    built_us = System.convert_time_unit(native, :native, :microsecond)
    assert %{full: %{count: 1, avg_us: parent_us}} = RenderMetrics.stats(module_of(parent, site))
    assert about?(parent_us, 500)

    assert built_us > parent_us,
           "the child's build (#{built_us} µs) is not in the parent's #{parent_us} µs"
  end

  describe "the component card" do
    defp card(record_attrs, metrics) do
      record =
        struct(
          Component,
          [
            id: "comp-1",
            name: "chelekom-button",
            site: %{name: "Global"},
            type: "general",
            format: :heex,
            priority: 50,
            active: true,
            dependencies: [],
            inserted_at: ~U[2026-01-01 10:00:00Z],
            updated_at: ~U[2026-01-02 10:00:00Z]
          ] ++ record_attrs
        )

      preview =
        PreviewHelpers.empty()
        |> Map.merge(%{
          resource: Component,
          record: record,
          active_tab: "overview",
          metrics: metrics
        })

      render_component(&RuntimePreviewModal.modal/1, preview: preview)
    end

    defp box(html, id),
      do: html |> LazyHTML.from_fragment() |> LazyHTML.query("##{id}") |> LazyHTML.text()

    test "with the setting off, Render Time says so and links to it; Cache still answers" do
      html = card([], %{on?: false, loaded?: true, stats: nil, build: nil})
      time = box(html, "runtime-preview-render-time")
      assert time =~ "Not active"
      assert time =~ "Turn it on in Settings"
      refute time =~ "live"
      assert box(html, "runtime-preview-rerenders") =~ "Not active"

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#runtime-preview-render-time a")
             |> LazyHTML.attribute("href") == ["/admin/dashboard/settings?tab=general"]

      assert box(html, "runtime-preview-cache") =~ "Loaded"
    end

    test "a global component's counts are every site's, so a site admin is not shown them" do
      html = card([], %{on?: true, loaded?: true, stats: :hidden, build: nil})

      for id <- ["runtime-preview-render-time", "runtime-preview-rerenders"] do
        assert box(html, id) =~ "—"
        assert box(html, id) =~ "shown to master admins"
      end
    end

    test "says Loading… in both runtime boxes until the read lands" do
      html = card([], :loading)
      assert box(html, "runtime-preview-render-time") =~ "Loading…"
      assert box(html, "runtime-preview-cache") =~ "Loading…"
    end

    test "a module not in memory yet says so" do
      html = card([], %{on?: true, loaded?: false, stats: nil, build: nil})
      assert box(html, "runtime-preview-render-time") =~ "Not loaded"
      assert box(html, "runtime-preview-cache") =~ "Not loaded"
      assert box(html, "runtime-preview-rerenders") =~ "Not loaded"
    end

    test "shows the averages and the build" do
      metrics = %{
        on?: true,
        loaded?: true,
        stats: %{full: %{count: 2, avg_us: 3000}, update: %{count: 5, avg_us: 40}},
        build: %{us: 11_000, cache: :miss, at: ~U[2026-10-28 12:00:00Z]}
      }

      html = card([precompile: true], metrics)
      time = box(html, "runtime-preview-render-time")
      assert time =~ "3.0 ms"
      assert time =~ "Average of 2 full renders"
      refute time =~ "updates"
      rerenders = box(html, "runtime-preview-rerenders")
      assert rerenders =~ "5"
      assert rerenders =~ "Average 40 µs each"
      assert box(html, "runtime-preview-cache") =~ "Compiled in 11.0 ms, saved to the disk cache"
      assert html =~ "2026-10-28 12:00"
      assert html =~ "Precompiled"
    end

    test "a lazy component is Dynamic, and a loaded one with no renders says so" do
      html = card([precompile: false], %{on?: true, loaded?: true, stats: nil, build: nil})
      assert html =~ "Dynamic"
      assert box(html, "runtime-preview-render-time") =~ "No renders"
      assert box(html, "runtime-preview-rerenders") =~ "0"
      assert box(html, "runtime-preview-cache") =~ "Loaded"
    end
  end
end
