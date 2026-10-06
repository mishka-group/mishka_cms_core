defmodule MishkaCmsCore.Runtime.ComponentSiteScopeTest do
  @moduledoc """
  Whose components a render reaches: the site this process renders for, and the global ones.

  A component reads as its own site — the kits read `authorize?: false` with `tenant: site_id()` —
  so a template on one site that wrote `<.component component_name="…" site="another">` drew that
  other site's markup and rows to its own visitors, inactive or offline as that site might be, and
  ran its `handle_event` besides. `MishkaCmsCore.Runtime.LiveViewHelpers.component/1` now refuses
  such a name before building it, and so does `static_component/1`, which the canvas and the
  previews render through.

  The site being rendered is the one `MishkaCmsCore.Runtime.Translations.put_site/1` named for the
  process — see the surfaces that name it in `MishkaCmsCore.Runtime.LiveViewHelpers`. A test process
  names it the same way a page does.

  `async: false` — `SiteState` and the event registry are process-global.
  """
  use MishkaCmsCore.DataCase, async: false

  alias MishkaCmsCore.Runtime.Compilers.{Helpers, ModuleCompiler}
  alias MishkaCmsCore.Runtime.{LiveViewHelpers, Page, RuntimePreview, Translations}
  alias MishkaCmsCore.Runtime.PageBuilder.CardPreview
  alias MishkaCmsCore.Runtime.States.{CompileFailureState, SiteState}
  alias MishkaCmsCore.Test.Plugins.ComponentUnavailable

  @moduletag :integration

  setup do
    %{home: site!("scope-home"), other: site!("scope-other")}
  end

  describe "component/1 — a page's own components and the global ones" do
    test "draws a component of the site the process renders for", %{home: home} do
      component = component!(home, "own")
      :ok = Translations.put_site(home.id)

      assert render(component.name, home.name) =~ "probe-own"
    end

    test "draws nothing for another site's component, and never builds it", %{
      home: home,
      other: other
    } do
      component = component!(other, "foreign")
      :ok = Translations.put_site(home.id)

      html = render(component.name, other.name)

      refute html =~ "probe-foreign"
      refute html =~ "failed to render"
      refute Helpers.loaded?(module_for(component.name, other.name))
    end

    test "a global component is drawn whichever site renders it", %{home: home, other: other} do
      component = component!(nil, "shared")

      for site_id <- [home.id, other.id, nil] do
        :ok = Translations.put_site(site_id)

        assert render(component.name, "Global") =~ "probe-shared"
        assert render(component.name, nil) =~ "probe-shared"
      end
    end

    # FAIL SAFE: a surface that never said which site it renders for reaches no site's components.
    test "a process that names no site draws no site's component", %{home: home} do
      component = component!(home, "unnamed")
      :ok = Translations.put_site(nil)

      refute render(component.name, home.name) =~ "probe-unnamed"
      refute Helpers.loaded?(module_for(component.name, home.name))
    end

    # A LIVE COMPONENT IS WHERE IT WOULD HURT MOST: its `handle_event` would run on the other site's
    # data, from this site's page. Refused before the live dispatch, so there is no component token
    # for LiveView to mount at all.
    test "another site's live component is refused before any live component is built", %{
      home: home,
      other: other
    } do
      component =
        component!(other, "live",
          stateful: true,
          template: ~S|<div id={@id} class="probe-live">live</div>|
        )

      :ok = Translations.put_site(home.id)

      rendered =
        LiveViewHelpers.component(%{component_name: component.name, site: other.name, id: "x"})

      refute match?(%Phoenix.LiveView.Component{}, rendered)
      refute to_html(rendered) =~ "probe-live"
      refute Helpers.loaded?(module_for(component.name, other.name))
    end

    # A GLOBAL LAYOUT IS COMPILED ONCE AND DRAWN ON EVERY SITE, so the site it may reach is the one it
    # is drawn on. A global component's markup is the same case, compiled the same way.
    test "a global template reaches the components of the site it is drawn on, not another's", %{
      home: home,
      other: other
    } do
      mine = component!(home, "host-home")
      theirs = component!(other, "host-other")

      frame =
        component!(nil, "frame",
          template: """
          <div class="probe-frame">
            <.component component_name="#{mine.name}" site="#{home.name}" />
            <.component component_name="#{theirs.name}" site="#{other.name}" />
          </div>
          """
        )

      :ok = Translations.put_site(home.id)
      on_home = render(frame.name, "Global")

      assert on_home =~ "probe-host-home"
      refute on_home =~ "probe-host-other"

      :ok = Translations.put_site(other.id)
      on_other = render(frame.name, "Global")

      assert on_other =~ "probe-host-other"
      refute on_other =~ "probe-host-home"
    end
  end

  describe "static_component/1 — the builder's canvas and the previews" do
    test "draws the site's own component and refuses another site's", %{home: home, other: other} do
      own = component!(home, "static-own")
      foreign = component!(other, "static-foreign")
      :ok = Translations.put_site(home.id)

      assert static(own.name, home.name) =~ "probe-static-own"

      html = static(foreign.name, other.name)

      refute html =~ "probe-static-foreign"
      refute html =~ "failed to render"
      refute Helpers.loaded?(module_for(foreign.name, other.name))
    end
  end

  describe "rendering_for/2 — a render for one site among several" do
    test "renders for the named site, then puts back the site the process rendered for", %{
      home: home,
      other: other
    } do
      component = component!(other, "scoped")
      :ok = Translations.put_site(home.id)

      html =
        LiveViewHelpers.rendering_for(other.name, fn ->
          assert Translations.site() == other.id
          render(component.name, other.name)
        end)

      assert html =~ "probe-scoped"
      assert Translations.site() == home.id
      refute render(component.name, other.name) =~ "probe-scoped"
    end

    test "Global, nil and a name no site has render for no site", %{home: home} do
      :ok = Translations.put_site(home.id)

      for name <- ["Global", nil, "scope-no-such-site-#{unique()}"] do
        assert LiveViewHelpers.rendering_for(name, &Translations.site/0) == nil
      end

      assert Translations.site() == home.id
    end
  end

  # AN ADMIN'S PROCESS PREVIEWS EVERY SITE'S RECORDS, one after another, so each preview names its
  # own site for as long as it renders and no longer. The test process starts out rendering for the
  # OTHER site, which is what a master's modal looks like after previewing that site's page first.
  describe "the admin's previews" do
    test "a page's preview draws its own site's components and not another's", %{
      home: home,
      other: other
    } do
      own = component!(home, "preview-own")
      foreign = component!(other, "preview-foreign")
      :ok = Translations.put_site(other.id)

      page = %{
        name: "Scoped",
        site: %{id: home.id, name: home.name},
        template: """
        <section>
          <.component component_name="#{own.name}" site="#{home.name}" />
          <.component component_name="#{foreign.name}" site="#{other.name}" />
        </section>
        """
      }

      {html, nil} = RuntimePreview.render_document(page, Page)

      assert html =~ "probe-preview-own"
      refute html =~ "probe-preview-foreign"
      assert Translations.site() == other.id
    end

    test "an error page's preview draws its own site's components and not another's", %{
      home: home,
      other: other
    } do
      own = component!(home, "error-own")
      foreign = component!(other, "error-foreign")
      :ok = Translations.put_site(other.id)

      record = %{
        name: "Errors",
        site: %{id: home.id, name: home.name},
        root_layout_template: nil,
        error_pages: [
          %{
            status: 404,
            layout: nil,
            template: """
            <div>
              <.component component_name="#{own.name}" site="#{home.name}" />
              <.component component_name="#{foreign.name}" site="#{other.name}" />
            </div>
            """
          }
        ]
      }

      {html, nil} = RuntimePreview.render_error_document(record, 404)

      assert html =~ "probe-error-own"
      refute html =~ "probe-error-foreign"
      assert Translations.site() == other.id
    end

    test "a component's example draws the named site's component", %{home: home, other: other} do
      own = component!(home, "example-own")
      :ok = Translations.put_site(other.id)

      {html, nil} =
        RuntimePreview.render_example(
          ~s(<.component component_name="#{own.name}" site="#{home.name}" />),
          home.name
        )

      assert html =~ "probe-example-own"
      assert Translations.site() == other.id
    end

    test "a palette card draws the editor's site's component and not another's", %{
      home: home,
      other: other
    } do
      own = component!(home, "card-own")
      foreign = component!(other, "card-foreign")
      :ok = Translations.put_site(other.id)

      {:ok, card} =
        CardPreview.document(
          ~s(<.component component_name="#{own.name}" site="#{home.name}" />),
          home.name
        )

      {:ok, stranger} =
        CardPreview.document(
          ~s(<.component component_name="#{foreign.name}" site="#{other.name}" />),
          home.name
        )

      assert card =~ "probe-card-own"
      refute stranger =~ "probe-card-foreign"
      assert Translations.site() == other.id
    end
  end

  # TWO NAMES, ONE MODULE. A module is named from `md5(name <> site)`, nothing between the two, so
  # `list` of `coffee-shop` and `listcoffee-` of `shop` are the same module, and so are `list` of
  # `coffeeshop` and `listcoffee` of `shop`. Whichever built it first answers to both names, so the
  # site asked for is checked against the site the module was built for.
  describe "a module is drawn for the site it was built for, whatever its name hashes to" do
    test "another site's live component is not drawn under a name of this site's", %{home: home} do
      coffee = named_site!("coffee-#{home.name}")

      theirs =
        component!(coffee, "collide-theirs",
          stateful: true,
          template: ~S|<div id={@id} class="probe-collide-theirs">theirs</div>|
        )

      alias_name = theirs.name <> "coffee-"
      assert module_for(alias_name, home.name) == module_for(theirs.name, coffee.name)

      # Built by a render on coffee's own page.
      assert LiveViewHelpers.ensure_component_loaded(theirs.name, coffee.name)

      register_plugin(ComponentUnavailable, "runtime:render:component_unavailable")
      :ok = Translations.put_site(home.id)

      rendered =
        LiveViewHelpers.component(%{component_name: alias_name, site: home.name, id: "x"})

      refute match?(%Phoenix.LiveView.Component{}, rendered)

      [note] = rendered |> to_html() |> refused()
      assert LazyHTML.attribute(note, "data-name") == [alias_name]
      assert LazyHTML.attribute(note, "data-site") == [home.name]
      assert LazyHTML.attribute(note, "data-rendering") == [home.id]

      refute static(alias_name, home.name) =~ "probe-collide-theirs"
    end

    test "this site's component, built first, is not drawn on the site its name hashes to", %{
      home: home
    } do
      # A component's name is a slug, so a row cannot end in `-`: this direction takes a site whose
      # name has none between the two parts.
      coffee = named_site!("coffee#{home.name}")
      base = "scope-collide-#{unique()}"

      ours =
        component!(home, "collide-ours",
          name: base <> "coffee",
          stateful: true,
          template: ~S|<div id={@id} class="probe-collide-ours">ours</div>|
        )

      assert module_for(ours.name, home.name) == module_for(base, coffee.name)

      :ok = Translations.put_site(home.id)
      assert LiveViewHelpers.ensure_component_loaded(ours.name, home.name)

      :ok = Translations.put_site(coffee.id)
      rendered = LiveViewHelpers.component(%{component_name: base, site: coffee.name, id: "x"})

      refute match?(%Phoenix.LiveView.Component{}, rendered)
      refute to_html(rendered) =~ "probe-collide-ours"
      refute static(base, coffee.name) =~ "probe-collide-ours"
    end

    # A SITE THAT IS GONE owns nothing: its name taken by a new site, the module its component left
    # behind is rebuilt for the new one rather than drawing nothing until a restart.
    test "a module left by a site that is gone is rebuilt for the site that has its name now" do
      name = "reborn-#{unique()}"
      old = named_site!(name)
      tag = "reborn-#{unique()}"

      component!(old, "reborn-old",
        name: tag,
        template: ~S|<div class="probe-reborn-old">old</div>|
      )

      :ok = Translations.put_site(old.id)
      assert render(tag, name) =~ "probe-reborn-old"

      SiteState.delete(old.id)
      Ash.destroy!(old, action: :permanent_destroy, authorize?: false)
      new = named_site!(name)

      component!(new, "reborn-new",
        name: tag,
        template: ~S|<div class="probe-reborn-new">new</div>|
      )

      :ok = Translations.put_site(new.id)
      html = render(tag, name)

      assert html =~ "probe-reborn-new"
      refute html =~ "probe-reborn-old"
    end
  end

  describe "runtime:render:component_unavailable" do
    test "a plugin hears the refusal, with what was asked and where, and may draw instead", %{
      home: home,
      other: other
    } do
      register_plugin(ComponentUnavailable, "runtime:render:component_unavailable")
      component = component!(other, "heard")
      :ok = Translations.put_site(home.id)

      [note] = component.name |> render(other.name) |> refused()

      assert LazyHTML.attribute(note, "data-name") == [component.name]
      assert LazyHTML.attribute(note, "data-site") == [other.name]
      assert LazyHTML.attribute(note, "data-rendering") == [home.id]
    end
  end

  defp site!(prefix), do: named_site!("#{prefix}-#{unique()}")

  defp named_site!(name) do
    site = create_site!(name: name, host: "#{name}.test")

    :ok =
      SiteState.save(%{id: site.id, name: site.name, host: site.host, priority: 0, active: true})

    on_exit(fn -> SiteState.delete(site.id) end)
    site
  end

  defp component!(site, tag, opts \\ []) do
    component =
      create_component!(
        Keyword.merge(
          [
            name: "scope-#{tag}-#{unique()}",
            template: ~s|<div class="probe-#{tag}">#{tag}</div>|,
            active: true,
            precompile: false,
            site_id: site && site.id
          ],
          opts
        )
      )

    module = module_for(component.name, site && site.name)

    on_exit(fn ->
      ModuleCompiler.unload(module)
      CompileFailureState.clear(module)
    end)

    component
  end

  defp module_for(name, site_name), do: Helpers.module_name(name, site_name, "Component")

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

  defp render(name, site),
    do: %{component_name: name, site: site} |> LiveViewHelpers.component() |> to_html()

  defp static(name, site),
    do: %{component_name: name, site: site} |> LiveViewHelpers.static_component() |> to_html()

  defp refused(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="refused"]))
    |> Enum.to_list()
  end

  defp to_html(rendered), do: rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  defp unique, do: System.unique_integer([:positive])
end
