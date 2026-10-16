# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Handlers.ComponentWarmTest do
  @moduledoc """
  A component that is not precompiled was built by the first visitor whose page named it: after a
  deploy, a docs page compiled six of them one after another before it answered. The site's warm job
  builds them first — what the site reaches and nothing else, a few at a time — and the first render
  finds them built.

  `async: false` — `SiteState`, the loaded code and the event registry are the node's.
  """
  use MishkaCmsCore.DataCase, async: false

  @repo Application.compile_env!(:mishka_cms_core, :repo)
  use Oban.Testing, repo: @repo

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.{LiveViewHelpers, Translations}
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SiteState}
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker
  alias MishkaCmsCore.Test.Plugins.{ContentComponentsNamed, WarmComponentsNarrowed}

  @compiling [:mishka_cms, :runtime, :compilers, :component, :start]

  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "warm-#{n}", host: "warm-#{n}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    runtime = Path.join(System.tmp_dir!(), "component_warm_#{n}")
    on_exit(fn -> File.rm_rf(runtime) end)

    %{site: site, runtime: runtime, n: n}
  end

  describe "warm_components/2" do
    test "builds what the site's pages reach, and what that reaches, and nothing else", %{
      site: site,
      runtime: runtime,
      n: n
    } do
      icon = component!(runtime, nil, "warm-icon-#{n}")

      card =
        component!(runtime, site, "warm-card-#{n}", ~s|<div>#{call(icon.name, "Global")}</div>|)

      spare = component!(runtime, site, "warm-spare-#{n}")
      unused_global = component!(runtime, nil, "warm-unused-#{n}")
      page!(runtime, site, call(card.name, site.name))

      refute built?(card.name, site.name)

      assert {:ok, %{warmed: warmed, failed: [], complete?: true}} = warm(site, runtime)

      assert Enum.sort_by(warmed, & &1.name) == [
               %{name: card.name, site: site.name},
               %{name: icon.name, site: "Global"}
             ]

      assert built?(card.name, site.name)
      assert built?(icon.name, "Global")
      refute built?(spare.name, site.name)
      refute built?(unused_global.name, "Global")
    end

    test "another site's pages warm nothing of this site's", %{site: site, runtime: runtime, n: n} do
      other = cached_site!("warm-other-#{n}")
      theirs = component!(runtime, other, "warm-theirs-#{n}")
      page!(runtime, other, call(theirs.name, other.name))

      assert {:ok, %{warmed: []}} = warm(site, runtime)
      refute built?(theirs.name, other.name)
    end

    test "the first render after it compiles nothing", %{site: site, runtime: runtime, n: n} do
      card =
        component!(runtime, site, "warm-first-#{n}", ~s|<div class="probe-first">first</div>|)

      page!(runtime, site, call(card.name, site.name))

      assert {:ok, %{warmed: [_card]}} = warm(site, runtime)

      watch_compiles([card.name])
      assert render(site, card.name) =~ "probe-first"
      refute_received {:compiling, _name, _pid}
    end

    test "without it, the first render is the one that compiles", %{site: site, n: n} do
      card = component!(nil, site, "warm-cold-#{n}", ~s|<div class="probe-cold">cold</div>|)

      watch_compiles([card.name])
      assert render(site, card.name) =~ "probe-cold"
      assert_received {:compiling, name, _pid}
      assert name == card.name
    end

    test "compiles at most :max_concurrency components at once", %{
      site: site,
      runtime: runtime,
      n: n
    } do
      names = for i <- 1..5, do: component!(runtime, nil, "warm-many-#{i}-#{n}").name
      page!(runtime, site, Enum.map_join(names, "\n", &call(&1, "Global")))
      watch_compiles(names, hold?: true)

      warm = Task.async(fn -> warm(site, runtime, max_concurrency: 2) end)

      running = for _ <- 1..2, do: compile_started!()
      refute_receive {:compiling, _name, _pid}, 300

      # EACH ONE THAT ENDS LETS EXACTLY ONE MORE START, and never a third beside the two.
      last =
        Enum.reduce(1..3, running, fn _step, [done | rest] ->
          send(done, :go)
          next = compile_started!()
          refute_receive {:compiling, _name, _pid}, 100
          rest ++ [next]
        end)

      Enum.each(last, &send(&1, :go))

      assert {:ok, %{warmed: warmed, failed: []}} = Task.await(warm, 15_000)
      assert warmed |> Enum.map(& &1.name) |> Enum.sort() == Enum.sort(names)
    end

    test "a component already built, or whose compile failed, is not compiled again", %{
      site: site,
      runtime: runtime,
      n: n
    } do
      built = component!(runtime, site, "warm-built-#{n}")
      broken = component!(runtime, site, "warm-broken-#{n}")
      page!(runtime, site, call(built.name, site.name) <> call(broken.name, site.name))

      assert LiveViewHelpers.ensure_component_loaded(built.name, site.name)
      :ok = CompileFailureState.record(module_for(broken.name, site.name), :compilation_error)

      watch_compiles([built.name, broken.name])

      assert {:ok, %{warmed: [], failed: []}} = warm(site, runtime)
      refute_received {:compiling, _name, _pid}
    end

    test "a component that does not compile is reported, and the rest are built", %{
      site: site,
      runtime: runtime,
      n: n
    } do
      good = component!(runtime, site, "warm-good-#{n}")
      bad = component!(runtime, site, "warm-bad-#{n}")
      page!(runtime, site, call(good.name, site.name) <> call(bad.name, site.name))

      # A SAVE REFUSES A TEMPLATE THAT DOES NOT COMPILE, so the stored one is broken behind it — as a
      # row written before that check, or by a kit, can be.
      {1, _rows} =
        from(c in "components", where: c.id == type(^bad.id, Ecto.UUID))
        |> @repo.update_all(set: [template: "<div>{@never</div>"])

      assert {:ok, %{warmed: [%{name: good_name}], failed: [%{name: bad_name}]}} =
               warm(site, runtime)

      assert good_name == good.name
      assert bad_name == bad.name
      assert CompileFailureState.failed?(module_for(bad.name, site.name))
    end

    # A STYLESHEET CANNOT BE BUILT FROM WHAT A WALK THAT GAVE UP REACHED; A WARM CAN. What it is sure
    # of is built, and the reference it could not follow is left to the render that meets it.
    test "a reference the walk cannot follow leaves the rest of what it reached warmed", %{
      site: site,
      runtime: runtime,
      n: n
    } do
      known = component!(runtime, nil, "warm-known-#{n}")
      dynamic = ~s|<.component component_name={@pick} site="Global" />|
      page!(runtime, site, call(known.name, "Global") <> dynamic)

      assert {:ok, %{complete?: false, warmed: [%{name: name}]}} = warm(site, runtime)
      assert name == known.name
    end

    test "builds the components the site's stored content names", %{site: site, runtime: runtime} do
      register_plugin(ContentComponentsNamed, "runtime:compile:content_components")
      named = component!(runtime, nil, "probe-from-content-#{site.name}")
      page!(runtime, site, ~s|<.rich_content id="body" html={@body} />|)

      assert {:ok, %{warmed: [%{name: name, site: "Global"}]}} = warm(site, runtime)
      assert name == named.name
      assert built?(named.name, "Global")
    end

    test "a plugin decides what is built, from the site's own and the global components only", %{
      site: site,
      runtime: runtime,
      n: n
    } do
      register_plugin(WarmComponentsNarrowed, "runtime:compile:warm_components")
      held = component!(runtime, site, "warm-#{n}-held")
      added = component!(nil, nil, "warm-from-plugin")
      page!(runtime, site, call(held.name, site.name))

      assert {:ok, %{warmed: [%{name: "warm-from-plugin", site: "Global"}]}} = warm(site, runtime)
      assert built?(added.name, "Global")
      refute built?(held.name, site.name)
    end

    test "a site SiteState does not know warms nothing", %{runtime: runtime} do
      assert BootHandler.warm_components("warm-nowhere", runtime_dir: runtime) ==
               {:error, :no_site}
    end
  end

  describe "the warm job" do
    test "a site's stylesheet build queues the site's warm job, for this instance", %{site: site} do
      perform_job(RuntimeCompilerWorker, bundle_args(site, "css"))

      assert_enqueued(
        worker: RuntimeCompilerWorker,
        queue: :maintenance,
        args: %{
          boot_id: BootHandler.boot_id(),
          data: %{site_name: site.name, site_id: site.id, type: "warm"}
        }
      )
    end

    test "runs the warm, and ends for a site that is gone", %{site: site} do
      assert :ok = perform_job(RuntimeCompilerWorker, bundle_args(site, "warm"))

      gone = %{site | name: "warm-gone-#{System.unique_integer([:positive])}"}
      assert :ok = perform_job(RuntimeCompilerWorker, bundle_args(gone, "warm"))
    end
  end

  def compiling(_event, _measurements, %{name: name}, %{test: test, names: names, hold?: hold?}) do
    if name in names do
      send(test, {:compiling, name, self()})
      if hold?, do: receive(do: (:go -> :ok), after: (15_000 -> :ok))
    end
  end

  defp watch_compiles(names, opts \\ []) do
    id = {__MODULE__, make_ref()}
    config = %{test: self(), names: names, hold?: Keyword.get(opts, :hold?, false)}
    :ok = :telemetry.attach(id, @compiling, &__MODULE__.compiling/4, config)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp compile_started! do
    assert_receive {:compiling, _name, pid}, 5_000
    pid
  end

  defp warm(site, runtime, opts \\ []),
    do: BootHandler.warm_components(site.name, Keyword.put(opts, :runtime_dir, runtime))

  # The row, and the template file boot writes for it — what the walk reads. `nil` for `runtime`
  # writes no file: a component no walk can find.
  defp component!(runtime, site, name, template \\ ~s|<div class="p-1">x</div>|) do
    row =
      create_component!(
        name: name,
        site_id: site && site.id,
        template: template,
        active: true,
        precompile: false
      )

    if runtime,
      do:
        write(
          runtime,
          scope(site),
          "component",
          name,
          BootHandler.build_component_class_content(row)
        )

    row
  end

  defp page!(runtime, site, template), do: write(runtime, site.name, "page", "home", template)

  defp write(runtime, scope, kind, name, source) do
    dir = Path.join([runtime, scope, kind])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}.template"), source)
  end

  defp scope(nil), do: "__global__"
  defp scope(site), do: site.name

  defp cached_site!(name) do
    site = create_site!(name: name, host: "#{name}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    site
  end

  defp call(name, site), do: ~s|<.component component_name="#{name}" site="#{site}" />|

  defp module_for(name, site), do: Helpers.module_name(name, site, "Component")

  defp built?(name, site), do: Helpers.loaded?(module_for(name, site))

  defp render(site, name) do
    :ok = Translations.put_site(site.id)

    %{component_name: name, site: site.name}
    |> LiveViewHelpers.component()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp bundle_args(site, type) do
    %{
      "resource" => "MishkaCmsCore.Runtime.Handlers.BootHandler",
      "action" => "boot_handler",
      "boot_id" => BootHandler.boot_id(),
      "data" => %{"site_name" => site.name, "site_id" => site.id, "type" => type}
    }
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
