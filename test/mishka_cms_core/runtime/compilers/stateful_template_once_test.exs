# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.StatefulTemplateOnceTest do
  @moduledoc """
  A stateful component's template is compiled into `render/1` alone, and every surface draws it
  exactly as it drew it when the bridge carried a copy of its own.

  ## Before and after, in one run

  The bridge's body used to be the same three steps as `render/1`'s — merge the defaults, run the
  body, render the template — so the template was compiled twice. `two_copies/2` rebuilds that
  module from today's AST by putting `render/1`'s body back into the bridge. Each component here is
  compiled both ways, under the module name the runtime resolves it to, and drawn through:

    * a published page — a page compiled by `LiveViewCompiler`, mounted in a LiveView, clicked;
    * the Preview and the draft-preview URL — `LiveViewCompiler.render_template/2`;
    * the builder's canvas — `LiveViewHelpers.static_component/1`;
    * a call of the bridge itself, the way a function component is called.

  The components: the live counter the kit exporter wrote (`cms_v3_live_seed.json`), installed and
  compiled from its row; and hand-written ones with a declared slot read through `:let`,
  `inner_block`, defaults of every type, a required attribute, a global attribute under its usual
  name and under another, a `body`, a helper with declarations of its own, a function component
  drawn inside a live one, and a site's copy of a component beside the global one of the same name.
  """
  use MishkaCmsCore.ConnCase, async: false

  import MishkaCmsCore.Test.Factory
  import Phoenix.LiveViewTest

  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Compilers.{LiveViewCompiler, ModuleCompiler}
  alias MishkaCmsCore.Runtime.Handlers.ModuleCompilerHandler
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Translations

  require Ash.Query

  @moduletag :integration

  @kit_bundle Path.expand("../../../fixtures/cms_v3_live_seed.json", __DIR__)
  @kit_component "livekit-sample-live-counter"

  @panel_template """
  <section
    id={@id}
    class={["once-panel", @class]}
    data-title={@title}
    data-tone={@tone}
    data-count={@count}
    data-opened={to_string(@opened)}
    {@rest}
  >
    <h2 data-role="heading">{@heading}</h2>
    <.tone_badge label={@tone} />
    <ol data-role="items">
      <li :for={{entry, index} <- Enum.with_index(assigns[:item] || [])} data-label={entry[:label]}>
        {render_slot(entry, index * @count)}
      </li>
    </ol>
    <div :if={!@hidden} data-role="inner">{render_slot(assigns[:inner_block] || [])}</div>
    <.component component_name="once-note" site={@site} text={@tone} />
    <button type="button" phx-click="toggle" phx-target={@myself}>toggle</button>
  </section>
  """

  @page """
  <main id="page">
    <.component
      component_name="once-panel"
      id="panel"
      title="Hello"
      tone="loud"
      count={3}
      class="extra"
      data-author="kept"
    >
      inner words
      <:item :let={n} label="first">first {n}</:item>
      <:item :let={n} label="second">second {n}</:item>
    </.component>
    <.component component_name="once-panel" id="panel-defaults" title="Defaults" />
    <.component component_name="once-globals" id="globals" aria-label="kept" />
    <.component component_name="once-scoped" site={@site_name} id="scoped-site" />
    <.component component_name="once-scoped" site="Global" id="scoped-global" label="global" />
    <.component
      component_name="livekit-sample-live-counter"
      id="counter"
      size="large"
      data-author="kept"
    />
  </main>
  """

  defmodule Host do
    use Phoenix.LiveView

    # What `MishkaCmsWeb.RuntimeLive` does with a compiled page: render it for its site.
    def mount(_params, session, socket) do
      :ok = MishkaCmsCore.Runtime.Translations.put_site(session["site_id"])

      {:ok,
       Phoenix.Component.assign(socket,
         page_module: session["page_module"],
         site_name: session["site_name"]
       )}
    end

    def render(assigns), do: assigns.page_module.render(assigns)
  end

  setup do
    SiteState.clear()
    n = System.unique_integer([:positive])
    site = create_site!(name: "once#{n}", host: "once#{n}.test", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> SiteState.clear() end)

    UiKitHandler.uninstall_kit!(@kit_bundle)
    {:ok, _installed} = UiKitHandler.install_kit!(@kit_bundle)
    on_exit(fn -> UiKitHandler.uninstall_kit!(@kit_bundle) end)

    create_component!(
      name: "once-note",
      template: ~s(<span data-role="note">{@text}</span>),
      attrs: [%{"name" => "text", "type" => "string", "opts" => %{"default" => "none"}}]
    )

    create_component!(
      name: "once-panel",
      stateful: true,
      template: @panel_template,
      body: "Map.put(assigns, :heading, String.upcase(assigns[:title] || \"\"))",
      attrs: [
        %{"name" => "title", "type" => "string", "opts" => %{"required" => true}},
        %{
          "name" => "tone",
          "type" => "string",
          "opts" => %{"default" => "calm", "values" => ["calm", "loud"]}
        },
        %{"name" => "count", "type" => "integer", "opts" => %{"default" => 2}},
        %{"name" => "hidden", "type" => "boolean", "opts" => %{"default" => false}},
        %{"name" => "class", "type" => "string", "opts" => %{"default" => nil}},
        %{"name" => "rest", "type" => "global", "opts" => %{}}
      ],
      slots: [
        %{"name" => "inner_block", "opts" => %{}},
        %{"name" => "item", "opts" => %{}}
      ],
      helpers: [
        %{
          "name" => "mount",
          "args" => "socket",
          "code" => "{:ok, Phoenix.Component.assign(socket, :opened, false)}"
        },
        %{
          "name" => "handle_event",
          "args" => ~s|"toggle", _params, socket|,
          "code" => "{:noreply, Phoenix.Component.update(socket, :opened, &(not &1))}"
        },
        %{
          "name" => "tone_badge",
          "args" => "assigns",
          "code" => ~s|~H"""\n<span data-role="badge">{@label}</span>\n"""|,
          "attrs" => [%{"name" => "label", "type" => "string", "opts" => %{"default" => "none"}}]
        }
      ]
    )

    create_component!(
      name: "once-globals",
      stateful: true,
      template: """
      <p id={@id} data-flag={to_string(@flag)} {@html_attrs}>
        {@label || "unset"} {render_slot(assigns[:inner_block] || [])}
      </p>
      """,
      attrs: [
        %{"name" => "id", "type" => "string", "opts" => %{"required" => true}},
        %{"name" => "flag", "type" => "boolean", "opts" => %{"default" => false}},
        %{"name" => "label", "type" => "string", "opts" => %{"default" => nil}},
        %{"name" => "html_attrs", "type" => "global", "opts" => %{}}
      ],
      slots: [%{"name" => "inner_block", "opts" => %{}}]
    )

    for {site_id, scope} <- [{nil, "global"}, {site.id, "site"}] do
      create_component!(
        name: "once-scoped",
        site_id: site_id,
        stateful: true,
        template: ~s(<div id={@id} data-scope="#{scope}" data-site={@site}>{@label}</div>),
        attrs: [%{"name" => "label", "type" => "string", "opts" => %{"default" => "scoped"}}]
      )
    end

    :ok = Translations.put_site(site.id)

    {:ok, site: site, stateful: stateful_rows(site)}
  end

  # THE MODULE THIS COMPILER EMITTED BEFORE: today's AST with `render/1`'s body copied back into the
  # bridge, which is the only place the two differ.
  defp two_copies(ast, name) do
    bridge = String.to_atom(name)

    {_ast, body} =
      Macro.prewalk(ast, nil, fn
        {:def, _meta, [{:render, _m, [_assigns]}, [do: body]]} = node, nil -> {node, body}
        node, found -> {node, found}
      end)

    assert body, "#{name} has no render/1 to copy the template from"

    Macro.prewalk(ast, fn
      {:def, meta, [{^bridge, head_meta, [assigns]}, [do: _call]]} ->
        {:def, meta, [{bridge, head_meta, [assigns]}, [do: body]]}

      node ->
        node
    end)
  end

  defp stateful_rows(site) do
    names = ["once-panel", "once-globals", "once-scoped", @kit_component]

    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(
      stateful == true and
        name in ^names and
        (is_nil(site_id) or site_id == ^site.id)
    )
    |> Ash.Query.load([:component_module, :site])
    |> Ash.read!(authorize?: false, page: [limit: 50])
    |> then(& &1.results)
  end

  defp scope(row), do: row.site && row.site.name

  # The way the runtime builds it: from the row, through the handler, by the first render that needs it.
  defp build!(rows, :once) do
    for row <- rows do
      ModuleCompiler.unload(row.component_module)
      assert LiveViewHelpers.ensure_component_loaded(row.name, scope(row))
    end
  end

  defp build!(rows, :two_copies) do
    for row <- rows do
      ModuleCompiler.unload(row.component_module)

      {:ok, ast} =
        ModuleCompilerHandler.get_data_from_database_to_ast(
          {{Atom.to_string(row.component_module), row}, %{}}
        )

      assert {:ok, _module, _diagnostics} =
               ModuleCompiler.compile_module(two_copies(ast, row.name))
    end
  end

  defp compile_page! do
    module = :"Elixir.StatefulTemplateOncePage#{System.unique_integer([:positive])}"

    ast =
      LiveViewCompiler.build_module(%{
        title: "Once",
        page_module: module,
        template: @page,
        events: []
      })

    {:ok, ^module, _diagnostics} = ModuleCompiler.compile_module(ast)
    on_exit(fn -> ModuleCompiler.unload(module) end)
    module
  end

  defp page_html(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#page")
    |> LazyHTML.to_html()
  end

  # The page as a visitor meets it, then after a click on each live component.
  defp published(page, site) do
    {:ok, view, _html} =
      live_isolated(Phoenix.ConnTest.build_conn(), Host,
        session: %{"page_module" => page, "site_id" => site.id, "site_name" => site.name}
      )

    first = page_html(view)
    view |> element("#panel button") |> render_click()
    toggled = page_html(view)
    view |> element("#counter button") |> render_click()
    bumped = page_html(view)

    [first, toggled, bumped]
  end

  defp preview(site), do: LiveViewCompiler.render_template(@page, %{site_name: site.name})

  defp slot(name, attrs, render) do
    Map.merge(attrs, %{
      __slot__: name,
      inner_block: fn _changed, argument -> render.(argument) end
    })
  end

  defp canvas(site) do
    [
      %{
        component_name: "once-panel",
        id: "canvas-panel",
        title: "Canvas",
        inner_block: [slot(:inner_block, %{}, fn _ -> "canvas words" end)]
      },
      %{component_name: "once-globals", id: "canvas-globals", flag: true},
      %{component_name: "once-scoped", site: site.name, id: "canvas-scoped-site"},
      %{component_name: "once-scoped", site: "Global", id: "canvas-scoped-global"},
      %{component_name: @kit_component, id: "canvas-counter"}
    ]
    |> Enum.map(fn assigns ->
      assigns
      |> Map.put(:__changed__, nil)
      |> LiveViewHelpers.static_component()
      |> rendered_to_string()
    end)
  end

  # A call of the bridge, as a function component is called — the declarations' wrapper and all. The
  # wrapper sweeps every undeclared key into the global attribute, so a template that reads `@myself`
  # or an assign its lifecycle sets raises here, and has to raise the same way in both shapes.
  defp bridged(site) do
    panel = %{
      id: "bridge-panel",
      title: "Bridge",
      opened: false,
      myself: nil,
      "data-author": "kept",
      inner_block: [slot(:inner_block, %{}, fn _ -> "bridge words" end)],
      item: [slot(:item, %{label: "only"}, &"item #{&1}")]
    }

    [
      {"once-panel", nil, panel},
      {"once-globals", nil,
       %{
         id: "bridge-globals",
         "aria-label": "kept",
         inner_block: [slot(:inner_block, %{}, fn _ -> "bridge words" end)]
       }},
      {"once-globals", nil, %{"aria-label": "kept"}},
      {"once-scoped", site.name, %{id: "bridge-scoped-site"}},
      {"once-scoped", nil, %{id: "bridge-scoped-global"}},
      {@kit_component, nil, %{id: "bridge-counter", count: 4, myself: nil}}
    ]
    |> Enum.map(fn {name, scope, assigns} ->
      module = MishkaCmsCore.Runtime.Compilers.Helpers.module_name(name, scope, "Component")

      outcome(fn ->
        apply(module, String.to_atom(name), [Map.put(assigns, :__changed__, nil)])
      end)
    end)
  end

  defp outcome(fun) do
    {:ok, rendered_to_string(fun.())}
  rescue
    error -> {:raised, Exception.message(error)}
  end

  defp drawn(page, site) do
    %{
      published: published(page, site),
      preview: preview(site),
      canvas: canvas(site),
      bridge: bridged(site)
    }
  end

  describe "a stateful component compiled with its template once" do
    test "draws what it drew with two copies, on every surface", %{site: site, stateful: rows} do
      assert length(rows) == 5,
             "expected 5 live components, got #{inspect(Enum.map(rows, & &1.name))}"

      page = compile_page!()

      build!(rows, :two_copies)
      before = drawn(page, site)

      build!(rows, :once)
      now = drawn(page, site)

      for surface <- [:published, :preview, :canvas, :bridge] do
        assert Map.fetch!(now, surface) == Map.fetch!(before, surface),
               "#{surface} drew something else with the template compiled once"
      end

      [first, toggled, bumped] = now.published

      for drawn <- [
            "first 0",
            "second 3",
            "inner words",
            ~s(data-author="kept"),
            ~s(aria-label="kept"),
            ~s(data-scope="site"),
            ~s(data-scope="global"),
            ~s(data-role="note"),
            ~s(data-role="badge"),
            "HELLO",
            "DEFAULTS"
          ] do
        assert first =~ drawn, "the page never drew #{drawn}, so the comparison is about nothing"
      end

      assert toggled =~ ~s(data-opened="true"), "the click on the panel did not reach it"
      assert bumped =~ "<span>1</span>", "the click on the counter did not reach it"

      assert is_binary(now.preview) and now.preview =~ "second 3"
      assert Enum.all?(now.canvas, &(&1 =~ ~s(id="canvas-)))

      assert [
               {:raised, swept},
               {:ok, globals},
               {:raised, missing},
               {:ok, scoped_site},
               {:ok, scoped_global},
               {:raised, counter}
             ] = now.bridge

      assert swept =~ "key :id not found", "the panel's id was not swept into @rest"
      assert globals =~ "bridge words" and globals =~ ~s(aria-label="kept")
      assert missing =~ "key :id not found", "a required attribute left out was supplied"
      assert scoped_site =~ ~s(data-scope="site") and scoped_global =~ ~s(data-scope="global")
      assert counter =~ "key :count not found", "the counter's own state reached its bridge"
    end

    # The closures HEEx compiles a template into are named after the function holding it. Asked of
    # the loaded module, so a build that put a copy back would be caught here.
    test "carries the template in render/1 and not in the bridge", %{stateful: rows} do
      closures = fn module, prefix ->
        for {name, _arity} <- module.module_info(:functions),
            String.starts_with?(Atom.to_string(name), prefix),
            do: name
      end

      build!(rows, :two_copies)

      for row <- rows do
        assert closures.(row.component_module, "-#{row.name}") != [],
               "the two-copy build of #{row.name} has no template in its bridge, so this asks nothing"
      end

      build!(rows, :once)

      for row <- rows do
        assert closures.(row.component_module, "-#{row.name}") == [],
               "#{row.name}'s bridge still carries a copy of the template"

        assert closures.(row.component_module, "-render/1-fun-") != [],
               "#{row.name}'s render/1 lost the template"
      end
    end
  end
end
