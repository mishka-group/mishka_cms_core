defmodule MishkaCmsCore.Runtime.ComponentLifecycleTest do
  @moduledoc """
  When a component becomes a module, and when it becomes CSS — the two are deliberately separate.

  A component earns a **module** by being rendered: `precompile` decides whether that happens at
  boot or on the first render that names it. It earns **CSS** by being active at all, because
  `MishkaCmsCore.Runtime.Handlers.BootHandler` writes its template file either way and that file is
  what `MishkaCmsCore.Runtime.Compilers.CssClosure` walks and Tailwind scans.

  Keeping them separate is what makes lazy compilation safe: were the template written only
  alongside the module, a component reached for the first time by a visitor would render before any
  stylesheet knew its classes, and arrive unstyled. Every test here is a guard on one half of that.

  See `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` for the render-time half.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.Handlers.BootHandler
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.States.CompileFailureState
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  @template ~s(<div class="lifecycle-probe rounded-xl">hello</div>)

  # The site's own name and host are unique per test: `SiteState.save/1` REFUSES a name or host
  # another row already holds, and the factory's default names repeat across the suite — so a shared
  # name means the save is silently rejected and every lookup here answers `:not_found`.
  setup do
    n = System.unique_integer([:positive])
    site = create_site!(name: "lifecycle-site-#{n}", host: "lifecycle-#{n}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> SiteState.delete(site.id) end)

    # The test process renders for this site, as a page on it would: a component of any other site
    # is not drawn at all — see `LiveViewHelpers.component/1`.
    :ok = Translations.put_site(site.id)

    %{site: site}
  end

  defp make_component(opts) do
    name = "lifecycle-#{Keyword.fetch!(opts, :tag)}-#{System.unique_integer([:positive])}"

    component =
      create_component!(
        Keyword.merge(
          [name: name, template: @template, active: true, precompile: false],
          Keyword.delete(opts, :tag)
        )
      )

    on_exit(fn ->
      component.name
      |> module_for(component.site_id)
      |> MishkaCmsCore.Runtime.Compilers.ModuleCompiler.unload()

      BootHandler.delete_template_file(site_name(component.site_id), "component", component.name)
    end)

    component
  end

  defp site_name(nil), do: nil

  defp site_name(site_id) do
    {:ok, site} = SiteState.get(site_id)
    site.name
  end

  defp module_for(name, site_id), do: Helpers.module_name(name, site_name(site_id), "Component")

  defp template_file(name, site_id) do
    MishkaCmsCore.Runtime.Helpers.static_temp_dir([
      "runtime",
      site_name(site_id) || "__global__",
      "component"
    ])
    |> Path.join("#{Slug.slugify(name)}.template")
  end

  describe "boot: precompile decides whether a module is built, active decides whether CSS is" do
    test "a precompiled component is a module at boot", %{site: site} do
      component = make_component(tag: "eager", precompile: true, site_id: site.id)

      assert :ok = BootHandler.compile_components(site.id)

      assert Helpers.loaded?(module_for(component.name, site.id))
      assert File.exists?(template_file(component.name, site.id))
    end

    # THE POINT OF THE FLAG. 251 installed components used to mean 251 modules in the VM on every
    # boot, for a site that renders a handful.
    test "a lazy component is NOT a module at boot", %{site: site} do
      component = make_component(tag: "lazy", precompile: false, site_id: site.id)

      assert :ok = BootHandler.compile_components(site.id)

      refute Helpers.loaded?(module_for(component.name, site.id))
    end

    # THE INVARIANT THE LAZY PATH RESTS ON. Its classes are in the site's stylesheet before anything
    # renders it, so the first visitor to reach it sees it styled rather than naked.
    test "a lazy component still writes its template, so its CSS is built anyway", %{site: site} do
      component = make_component(tag: "lazycss", precompile: false, site_id: site.id)

      assert :ok = BootHandler.compile_components(site.id)

      assert File.read!(template_file(component.name, site.id)) =~ "lifecycle-probe"
    end

    test "an inactive component gets neither a module nor a template", %{site: site} do
      component = make_component(tag: "off", precompile: true, active: false, site_id: site.id)

      assert :ok = BootHandler.compile_components(site.id)

      refute Helpers.loaded?(module_for(component.name, site.id))
      refute File.exists?(template_file(component.name, site.id))
    end

    # AN ATTRIBUTE'S DEFAULT IS A CLASS NO CALL SITE EVER WRITES. Set `font_weight` on a component
    # and the value lands in the PAGE's template, which is scanned; leave it alone and the component
    # renders with a class Tailwind never saw. That is why `font-normal` and `leading-5` had no rule
    # on any site while every colour an author had chosen did.
    test "the template file carries attribute and slot defaults", %{site: site} do
      component =
        make_component(
          tag: "defaults",
          site_id: site.id,
          attrs: [
            %{
              name: "font_weight",
              type: "string",
              opts: %{"default" => "font-normal", "values" => ["font-normal", "font-black"]}
            }
          ],
          slots: [%{name: "inner_block", opts: %{"default" => "leading-5"}}]
        )

      assert :ok = BootHandler.compile_components(site.id)
      contents = File.read!(template_file(component.name, site.id))

      assert contents =~ "font-normal", "the attribute default never reaches Tailwind"
      assert contents =~ "leading-5", "the slot default never reaches Tailwind"

      refute contents =~ "font-black",
             "every option of every reachable component would go back into the bundle this shrinks"
    end

    # The template is the aggregate Tailwind scans, not just `template` — a class that only ever
    # appears in a helper's code or a clause is still a class the site has to ship a rule for.
    test "the template file carries body and helpers, not only the template", %{site: site} do
      component =
        make_component(
          tag: "blob",
          site_id: site.id,
          body: "assigns = Map.put(assigns, :extra, \"body-only-class\")",
          helpers: [%{name: "tone", code: "def tone, do: \"helper-only-class\""}]
        )

      assert :ok = BootHandler.compile_components(site.id)
      contents = File.read!(template_file(component.name, site.id))

      assert contents =~ "lifecycle-probe"
      assert contents =~ "body-only-class"
      assert contents =~ "helper-only-class"
    end
  end

  describe "render: the first use of a lazy component builds it" do
    test "rendering compiles the module and returns the component's own markup", %{site: site} do
      component = make_component(tag: "first", precompile: false, site_id: site.id)
      module = module_for(component.name, site.id)

      assert :ok = BootHandler.compile_components(site.id)
      refute Helpers.loaded?(module)

      html = render(component.name, site.name)

      assert Helpers.loaded?(module)
      assert html =~ "lifecycle-probe"
      refute html =~ "failed to render"
    end

    test "a global component resolves under the Global hash, from the rows with no site" do
      component = make_component(tag: "global", precompile: false, site_id: nil)
      module = module_for(component.name, nil)

      assert :ok = BootHandler.compile_components()
      refute Helpers.loaded?(module)

      assert render(component.name, "Global") =~ "lifecycle-probe"
      assert Helpers.loaded?(module)
    end

    # AN OPERATOR SWITCHED IT OFF. `Component.by_name` filters on `active`, which is the only thing
    # standing between "deactivated" and "compiled anyway by the next visitor".
    test "an inactive component is never built, however it is reached", %{site: site} do
      component = make_component(tag: "offrender", active: false, site_id: site.id)

      assert render(component.name, site.name) =~ "failed to render"
      refute Helpers.loaded?(module_for(component.name, site.id))
    end

    test "a name no component has renders the placeholder rather than raising", %{site: site} do
      assert render("lifecycle-nothing-#{System.unique_integer([:positive])}", site.name) =~
               "failed to render"
    end

    # A site name `SiteState` does not know belongs to an archived or deleted site. Reading the row
    # with no tenant would find the GLOBAL component of that name and compile it under the tenant's
    # module hash — one component answering to two identities. It is not the site being rendered
    # either, so it is refused before anything is built.
    test "a site that is not in SiteState does not fall back to the global row" do
      component = make_component(tag: "orphan", site_id: nil)
      orphan = Helpers.module_name(component.name, "lifecycle-no-such-site", "Component")

      refute render(component.name, "lifecycle-no-such-site") =~ "lifecycle-probe"
      refute Helpers.loaded?(orphan)
      refute Helpers.loaded?(module_for(component.name, nil))
    end
  end

  describe "ensure_component_loaded/2 — for callers that read metadata before rendering" do
    # THE PAGE BUILDER'S CANVAS ASKS A COMPONENT WHAT IT DECLARES, and a component that has never
    # been built declares nothing — so every attribute an author had set was dropped from the
    # preview and the node rendered with defaults. Reading the metadata is a use of the component,
    # so it builds it.
    test "a lazy component reports its declared attrs once ensured", %{site: site} do
      component =
        make_component(
          tag: "attrs",
          site_id: site.id,
          attrs: [%{name: "tone", type: "string", default: "quiet"}]
        )

      module = module_for(component.name, site.id)

      assert :ok = BootHandler.compile_components(site.id)
      refute Helpers.loaded?(module)

      assert LiveViewHelpers.ensure_component_loaded(component.name, site.name)
      assert Helpers.loaded?(module)

      names =
        module
        |> apply(:__component_information__, [[:component, :attrs]])
        |> Enum.map(& &1.name)

      assert "tone" in names
    end

    test "it answers false for a name nothing resolves, rather than raising", %{site: site} do
      refute LiveViewHelpers.ensure_component_loaded("lifecycle-absent-#{unique()}", site.name)
    end

    # The canvas asks for a component under whatever `site` an author typed, without going through
    # `component/1`'s site check. A name `SiteState` does not know must still not read the GLOBAL
    # row and compile it under the tenant's module hash.
    test "a site that is not in SiteState does not fall back to the global row" do
      component = make_component(tag: "orphan-ensure", site_id: nil)
      orphan = Helpers.module_name(component.name, "lifecycle-no-such-site", "Component")
      on_exit(fn -> MishkaCmsCore.Runtime.Compilers.ModuleCompiler.unload(orphan) end)

      refute LiveViewHelpers.ensure_component_loaded(component.name, "lifecycle-no-such-site")
      refute Helpers.loaded?(orphan)
      refute Helpers.loaded?(module_for(component.name, nil))
    end
  end

  describe "an unresolvable name is remembered, so it is asked once" do
    # `ModuleCompilerHandler` leaves `:not_found` uncached on purpose, which is right for a page:
    # routing rejects an unknown path first, and a page created later must compile. A component has
    # no routing table, so without this every render of a template naming a component that is gone
    # would start a supervised worker and query the database again.
    test "a missing component records a failure the next render short-circuits on", %{site: site} do
      name = "lifecycle-ghost-#{System.unique_integer([:positive])}"
      module = module_for(name, site.id)
      on_exit(fn -> CompileFailureState.clear(module) end)

      assert render(name, site.name) =~ "failed to render"
      assert CompileFailureState.failed?(module)
    end

    # The memory has to end somewhere, and this is the event that ends it: a component of that name
    # now exists, has been switched on, or has been edited.
    test "the compile worker forgets it when a component of that name appears", %{site: site} do
      name = "lifecycle-arrives-#{System.unique_integer([:positive])}"
      module = module_for(name, site.id)
      on_exit(fn -> CompileFailureState.clear(module) end)

      CompileFailureState.record(module, :not_found)

      RuntimeCompilerWorker.apply_component_lifecycle(
        "create",
        %{"name" => name, "site_id" => site.id, "active" => true, "precompile" => false},
        module
      )

      on_exit(fn -> BootHandler.delete_template_file(site.name, "component", name) end)

      refute CompileFailureState.failed?(module)
    end
  end

  describe "reading a component by name is not the same question as compiling one" do
    # The compile path filters `active` at the CALL SITE. Baking it into the action would make the
    # admin unable to open an inactive component at all, which is the one place that has to.
    test "by_name still answers with an inactive component", %{site: site} do
      component = make_component(tag: "readable", active: false, site_id: site.id)

      assert {:ok, found} =
               MishkaCmsCore.Runtime.get_component_by_name(component.name,
                 tenant: site.id,
                 authorize?: false
               )

      assert found.id == component.id
      refute found.active
    end
  end

  defp unique, do: System.unique_integer([:positive])

  defp render(name, site) do
    %{component_name: name, site: site}
    |> LiveViewHelpers.component()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
