# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ComponentPrefetchTest do
  @moduledoc """
  The first render of a cold page met its components one after another, a child only once its
  parent was drawn, and compiled each in turn. A page or layout module now builds what it reaches
  several at a time before it draws — through the same registry, workers and compile gate, with at
  most its share of the gate, and nothing at all once it is built.

  `async: false` — the compile gate, the loaded code, `SiteState` and the event registry are the
  node's. Compiles are held at their start (`[:mishka_cms, :runtime, :compilers, :component, :start]`)
  so what runs at once is read from telemetry and the gate's own state, never from a clock.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.ComponentPrefetch
  alias MishkaCmsCore.Runtime.Compilers.{CssClosure, Helpers}
  alias MishkaCmsCore.Runtime.Handlers.{BootHandler, CompileGate, ModuleCompilerHandler}
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SiteState}
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaCmsCore.Test.Plugins.PrefetchComponentsNarrowed
  alias MishkaCmsCore.Test.RuntimePageHostLive

  @endpoint MishkaCmsCore.TestEndpoint

  @compiling [:mishka_cms, :runtime, :compilers, :component, :start]
  @prefetching [:mishka_cms, :runtime, :component_prefetch, :start]
  @prefetched [:mishka_cms, :runtime, :component_prefetch, :stop]

  setup do
    n = System.unique_integer([:positive])
    site = cached_site!("prefetch-#{n}")
    previous = Application.fetch_env(:mishka_cms_core, :component_prefetch_share)
    Application.delete_env(:mishka_cms_core, :component_prefetch_share)

    on_exit(fn ->
      case previous do
        {:ok, share} -> Application.put_env(:mishka_cms_core, :component_prefetch_share, share)
        :error -> Application.delete_env(:mishka_cms_core, :component_prefetch_share)
      end
    end)

    %{site: site, n: n, slots: max(1, div(CompileGate.limit(), 2))}
  end

  describe "a cold page" do
    test "builds what it reaches several at once, before it draws", %{
      site: site,
      n: n,
      slots: slots
    } do
      icon = component!(nil, "pf-icon-#{n}", ~s|<i class="probe-icon">i</i>|)

      cards =
        for i <- 1..3,
            do: component!(nil, "pf-card-#{i}-#{n}", ~s|<div>card #{i}#{call(icon.name)}</div>|)

      page = page!(site, Enum.map_join(cards, "\n", &call(&1.name)))
      names = [icon.name | Enum.map(cards, & &1.name)]
      watch_compiles(names, hold?: true)
      watch(@prefetched)

      drawing = Task.async(fn -> draw(page, site) end)

      # AS MANY AS ITS SHARE RUN AT ONCE, all held: none has ended when the last of them starts.
      at_once = min(slots, length(names))
      running = for _ <- 1..at_once, do: compile_started!()
      assert length(Enum.uniq(running)) == at_once
      Enum.each(running, &send(&1, :go))
      release(length(names) - at_once)

      html = Task.await(drawing, 15_000)
      for i <- 1..3, do: assert(html =~ "card #{i}")
      assert html =~ "probe-icon"

      assert_receive {:telemetry, @prefetched, %{asked: 4, built: 4, failed: 0}}
      for name <- names, do: assert(built?(name, "Global"))
    end

    test "takes at most its share of the compile gate", %{site: site, n: n, slots: slots} do
      names = for i <- 1..(slots + 3), do: component!(nil, "pf-share-#{i}-#{n}").name
      page = page!(site, Enum.map_join(names, "\n", &call/1))
      watch_compiles(names, hold?: true)

      drawing = Task.async(fn -> draw(page, site) end)

      running = for _ <- 1..slots, do: compile_started!()
      refute_receive {:compiling, _name, _pid}, 300
      assert :sys.get_state(CompileGate).used == slots

      # EACH ONE THAT ENDS LETS EXACTLY ONE MORE START, and never one beside the share.
      last =
        Enum.reduce(1..3, running, fn _step, [done | rest] ->
          send(done, :go)
          next = compile_started!()
          refute_receive {:compiling, _name, _pid}, 100
          rest ++ [next]
        end)

      Enum.each(last, &send(&1, :go))
      html = Task.await(drawing, 15_000)

      for name <- names, do: assert(built?(name, "Global"))
      refute html =~ "failed to render"
    end

    test "leaves another request's compile a slot", %{site: site, n: n, slots: slots} do
      held = for i <- 1..(slots + 2), do: component!(nil, "pf-busy-#{i}-#{n}").name
      busy = page!(site, Enum.map_join(held, "\n", &call/1))
      other_site = cached_site!("prefetch-other-#{n}")
      theirs = component!(other_site, "pf-theirs-#{n}", ~s|<div class="probe-theirs">t</div>|)
      other = page!(other_site, call(theirs.name, other_site.name))

      watch_compiles(held, hold?: true)
      watch_compiles([theirs.name])

      drawing = Task.async(fn -> draw(busy, site) end)
      running = for _ <- 1..slots, do: compile_started!()

      # The other site's first visitor is not queued behind this page.
      assert draw(other, other_site) =~ "probe-theirs"
      assert_received {:compiling, name, _pid}
      assert name == theirs.name

      Enum.each(running, &send(&1, :go))
      release(2)
      Task.await(drawing, 15_000)
    end

    test "is built in a LiveView's own render", %{site: site, n: n} do
      card = component!(site, "pf-live-#{n}", ~s|<div class="probe-live">live</div>|)
      page = page!(site, call(card.name, site.name))
      watch(@prefetched)

      session = %{"page_module" => Atom.to_string(page), "site_id" => site.id}
      {:ok, view, _html} = live_isolated(build_conn(), RuntimePageHostLive, session: session)

      assert has_element?(view, ".probe-live")
      assert_received {:telemetry, @prefetched, %{built: 1}}
    end

    test "builds a layout's components before the layout draws", %{site: site, n: n} do
      nav = component!(nil, "pf-nav-#{n}", ~s|<nav class="probe-nav">nav</nav>|)

      layout =
        create_layout!(
          site_id: site.id,
          name: "pf-layout-#{n}",
          path: "/pf-layout-#{n}",
          template: ~s|<div>#{call(nav.name)}{@inner_content}</div>|
        )

      module = Helpers.module_name(layout.id, site.name, "Layout")

      assert {:ok, ^module} =
               ModuleCompilerHandler.compile_or_return_module(
                 module,
                 layout.path,
                 site.name,
                 site.id
               )

      watch(@prefetched)
      :ok = Translations.put_site(site.id)

      html =
        %{__changed__: nil}
        |> module.render(Phoenix.HTML.raw("<p>inside</p>"))
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      assert html =~ "probe-nav"
      assert_received {:telemetry, @prefetched, %{built: 1}}
    end
  end

  describe "a built page" do
    test "builds nothing, reads nothing, and asks no plugin", %{site: site, n: n} do
      icon = component!(nil, "pf-warm-icon-#{n}")
      card = component!(site, "pf-warm-card-#{n}", "<div>#{call(icon.name)}</div>")
      page = page!(site, call(card.name, site.name))

      draw(page, site)
      assert built?(card.name, site.name) and built?(icon.name, "Global")

      watch(@prefetching)
      watch_compiles([card.name, icon.name])
      watch_queries()

      draw(page, site)

      refute_received {:telemetry, @prefetching, _meta}
      refute_received {:compiling, _name, _pid}
      refute_received {:query, _source}
    end

    test "a component whose compile failed is not asked again", %{site: site, n: n} do
      broken = component!(site, "pf-known-broken-#{n}")
      :ok = CompileFailureState.record(module_for(broken.name, site.name), :compilation_error)
      page = page!(site, call(broken.name, site.name))
      watch(@prefetching)

      draw(page, site)

      refute_received {:telemetry, @prefetching, _meta}
    end
  end

  describe "a component that does not compile" do
    test "fails as it does in a render, and the rest of the page is drawn", %{site: site, n: n} do
      good = component!(site, "pf-good-#{n}", ~s|<div class="probe-good">good</div>|)
      bad = component!(site, "pf-bad-#{n}")
      page = page!(site, call(good.name, site.name) <> call(bad.name, site.name))
      watch(@prefetched)

      # A SAVE REFUSES A TEMPLATE THAT DOES NOT COMPILE, so the stored one is broken behind it — as
      # a row written before that check, or by a kit, can be.
      {1, _rows} =
        from(c in "components", where: c.id == type(^bad.id, Ecto.UUID))
        |> @repo.update_all(set: [template: "<div>{@never</div>"])

      html = draw(page, site)

      assert html =~ "probe-good"
      assert html =~ "#{bad.name} Component failed to render!"
      assert CompileFailureState.failed?(module_for(bad.name, site.name))
      assert_received {:telemetry, @prefetched, %{built: 1, failed: 1}}
    end

    test "a name no component answers to is remembered, as a render remembers it", %{
      site: site,
      n: n
    } do
      # A template file left behind by a component whose row is gone.
      name = "pf-gone-#{n}"
      dir = Path.join([CssClosure.default_runtime_dir(), site.name, "component"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "#{name}.template"), "<div></div>")
      page = page!(site, call(name, site.name))
      watch(@prefetched)

      html = draw(page, site)

      assert html =~ "failed to render"
      assert CompileFailureState.failed?(module_for(name, site.name))
      assert_received {:telemetry, @prefetched, %{asked: 1, failed: 1}}
    end
  end

  describe "which copy is built" do
    test "the global copy a tag names, though the site has its own", %{site: site, n: n} do
      name = "pf-copy-#{n}"
      component!(nil, name, ~s|<div class="probe-global">global</div>|)
      component!(site, name, ~s|<div class="probe-own">own</div>|)
      page = page!(site, call(name, "Global"))

      assert draw(page, site) =~ "probe-global"
      assert built?(name, "Global")
      refute built?(name, site.name)
    end

    test "the site's own copy a tag names, though a global one exists", %{site: site, n: n} do
      name = "pf-own-#{n}"
      component!(nil, name, ~s|<div class="probe-global">global</div>|)
      component!(site, name, ~s|<div class="probe-own">own</div>|)
      page = page!(site, call(name, site.name))

      assert draw(page, site) =~ "probe-own"
      assert built?(name, site.name)
      refute built?(name, "Global")
    end

    test "never another site's", %{site: site, n: n} do
      other = cached_site!("prefetch-elsewhere-#{n}")
      theirs = component!(other, "pf-elsewhere-#{n}")
      page = page!(site, call(theirs.name, other.name))

      draw(page, site)

      refute built?(theirs.name, other.name)
    end
  end

  describe "runtime:compile:before_page_prefetch" do
    test "a plugin decides what is built, from the site's own and the global components only", %{
      site: site,
      n: n
    } do
      register_plugin(PrefetchComponentsNarrowed, "runtime:compile:before_page_prefetch")
      held = component!(site, "pf-#{n}-held")
      added = component!(nil, "prefetch-from-plugin")
      watch(@prefetched)
      page = page!(site, call(held.name, site.name))

      draw(page, site)

      assert_received {:telemetry, @prefetched, %{asked: 1, built: 1}}
      assert built?(added.name, "Global")
      # The page still draws the one the plugin held back; its render builds it, as before.
      assert built?(held.name, site.name)
    end
  end

  describe "turned off" do
    test "a share of 0 builds nothing ahead, and the render builds what it draws", %{
      site: site,
      n: n
    } do
      Application.put_env(:mishka_cms_core, :component_prefetch_share, 0)
      card = component!(site, "pf-off-#{n}", ~s|<div class="probe-off">off</div>|)
      page = page!(site, call(card.name, site.name))
      watch(@prefetching)

      assert ComponentPrefetch.slots() == 0
      assert draw(page, site) =~ "probe-off"
      refute_received {:telemetry, @prefetching, _meta}
    end

    test "the default share is half the gate, and at least one" do
      assert ComponentPrefetch.slots() == max(1, div(CompileGate.limit(), 2))

      Application.put_env(:mishka_cms_core, :component_prefetch_share, 0.01)
      assert ComponentPrefetch.slots() == 1

      Application.put_env(:mishka_cms_core, :component_prefetch_share, 5)
      assert ComponentPrefetch.slots() == CompileGate.limit()
    end
  end

  def compiling(_event, _measurements, %{name: name}, %{test: test, names: names, hold?: hold?}) do
    if name in names do
      send(test, {:compiling, name, self()})
      if hold?, do: receive(do: (:go -> :ok), after: (15_000 -> :ok))
    end
  end

  def forward(event, _measurements, metadata, %{test: test}),
    do: send(test, {:telemetry, event, metadata})

  def query(_event, _measurements, metadata, %{test: test}),
    do: send(test, {:query, metadata[:source]})

  defp watch_compiles(names, opts \\ []) do
    id = {__MODULE__, make_ref()}
    config = %{test: self(), names: names, hold?: Keyword.get(opts, :hold?, false)}
    :ok = :telemetry.attach(id, @compiling, &__MODULE__.compiling/4, config)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp watch(event) do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(id, event, &__MODULE__.forward/4, %{test: self()})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp watch_queries do
    id = {__MODULE__, make_ref()}
    default = @repo |> Module.split() |> Enum.map(&(&1 |> Macro.underscore() |> String.to_atom()))
    event = Keyword.get(@repo.config(), :telemetry_prefix, default) ++ [:query]
    :ok = :telemetry.attach(id, event, &__MODULE__.query/4, %{test: self()})
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp compile_started! do
    assert_receive {:compiling, _name, pid}, 5_000
    pid
  end

  # The next `count` compiles to start, each let go as it starts.
  defp release(count), do: for(_ <- 1..count//1, do: send(compile_started!(), :go))

  # The row, and the template file the boot writes for it — what a cold render walks.
  defp component!(site, name, template \\ ~s|<div class="p-1">x</div>|) do
    row =
      create_component!(
        name: name,
        site_id: site && site.id,
        template: template,
        active: true,
        precompile: false
      )

    dir = Path.join([CssClosure.default_runtime_dir(), scope(site), "component"])
    path = Path.join(dir, "#{name}.template")
    File.mkdir_p!(dir)
    File.write!(path, BootHandler.build_component_class_content(row))
    on_exit(fn -> File.rm(path) end)

    row
  end

  # A page module built from `template`, as a request's mount builds it.
  defp page!(site, template) do
    page =
      create_page!(
        site_id: site.id,
        path: "/pf-#{System.unique_integer([:positive])}",
        template: template,
        active: true,
        precompile: false
      )

    module = Helpers.module_name(page.id, site.name, "Page")

    {:ok, ^module} =
      ModuleCompilerHandler.compile_or_return_module(module, page.path, site.name, site.id)

    module
  end

  # One request: the process names the site it renders for, as the runtime LiveView's mount does.
  defp draw(module, site) do
    :ok = Translations.put_site(site.id)

    %{flash: %{}, __changed__: nil}
    |> module.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp scope(nil), do: "__global__"
  defp scope(site), do: site.name

  defp call(name, site \\ "Global"),
    do: ~s|<.component component_name="#{name}" site="#{site}" />|

  defp module_for(name, site), do: Helpers.module_name(name, site, "Component")

  defp built?(name, site), do: Helpers.loaded?(module_for(name, site))

  defp cached_site!(name) do
    site = create_site!(name: name, host: "#{name}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> File.rm_rf(Path.join(CssClosure.default_runtime_dir(), name)) end)
    site
  end

  defp register_plugin(module, event) do
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
end
