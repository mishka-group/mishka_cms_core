# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.CompilerIntegrationTest do
  @moduledoc """
  Direct tests for the v3-era compiler features:

    * `extra.prelude` — extra `import`/`alias`/`use` lines spliced at
      module top.
    * `extra.module_attributes` — `@key value` pairs registered with
      `persist: true` so they survive into `module_info(:attributes)`.
    * `extra.clauses` — pattern-matched function heads dispatched via
      `case assigns do ... end` inside the function body.

  These tests build params by hand (no bundle, no installer) so the
  compiler is exercised in isolation.
  """

  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias MishkaCmsCore.Runtime.Compilers.{ComponentCompiler, ModuleCompiler}

  @moduletag :unit

  defp compile_with(params, mod_suffix) do
    component_module =
      Module.concat([
        "MishkaCmsCore",
        "Runtime",
        "CompilerIntegrationTest#{mod_suffix}",
        "Component"
      ])

    full_params =
      Map.merge(
        %{
          id: "test-#{mod_suffix}",
          title: "test_component",
          component_module: component_module,
          site: "Test",
          site_id: nil,
          host: nil,
          format: :heex,
          priority: 50,
          timestamp: ~U[2026-01-01 00:00:00Z],
          attrs: [],
          slots: [],
          helpers: [],
          permissions: [],
          template: "",
          body: nil,
          extra: %{},
          prelude: nil,
          module_attributes: [],
          clauses: []
        },
        params
      )

    ast = ComponentCompiler.build_module(full_params)
    {:ok, module, _} = ModuleCompiler.compile_module(ast)
    module
  end

  describe "compiler edit — multi-clause via extra.clauses" do
    test "pattern-matched dispatch routes correctly" do
      module =
        compile_with(
          %{
            title: "icon_like",
            attrs: [
              %{name: "name", type: "string", opts: %{required: true}},
              %{name: "class", type: "any", opts: %{default: nil}},
              %{name: "rest", type: "global", opts: %{}}
            ],
            clauses: [
              %{
                "match" => "%{name: \"hero-\" <> _} = assigns",
                "body" => nil,
                "template" => "<span class={[@name, @class]} {@rest}/>"
              },
              %{
                "match" => nil,
                "body" => nil,
                "template" => "<span class={[\"unknown\", @class]} {@rest}>{@name}</span>"
              }
            ]
          },
          "MultiClause1"
        )

      assert :erlang.module_loaded(module)
      assert function_exported?(module, :icon_like, 1)

      hero =
        apply(module, :icon_like, [%{name: "hero-bell", class: nil, rest: %{}, __changed__: nil}])

      assert match?(%Phoenix.LiveView.Rendered{}, hero)

      other =
        apply(module, :icon_like, [%{name: "fa-star", class: nil, rest: %{}, __changed__: nil}])

      assert match?(%Phoenix.LiveView.Rendered{}, other)
    end
  end

  describe "compiler edit — module_attributes" do
    test "@key value persists into module_info(:attributes)" do
      module =
        compile_with(
          %{
            title: "with_attrs",
            template: "<div>x</div>",
            module_attributes: [
              %{"name" => "positions", "value" => ["start", "center", "end"]}
            ]
          },
          "ModAttrs1"
        )

      attrs = module.module_info(:attributes)
      assert {:positions, value} = List.keyfind(attrs, :positions, 0)
      assert value == ["start", "center", "end"]
    end
  end

  describe "compiler edit — extra.prelude" do
    test "user-supplied alias resolves inside the compiled module" do
      module =
        compile_with(
          %{
            title: "with_prelude",
            template: "<div>{Helpers.thing()}</div>",
            prelude: "alias Phoenix.LiveView.AsyncResult, as: Helpers",
            helpers: [
              %{
                "name" => "ignored",
                "args" => "_",
                "code" => "nil"
              }
            ]
          },
          "Prelude1"
        )

      # Module compiles cleanly — the alias is in scope.
      assert :erlang.module_loaded(module)
    end
  end

  describe "compiler edit — Tier-1 imports always available" do
    test "random_id/0 callable from helpers without explicit import" do
      module =
        compile_with(
          %{
            title: "tier1_user",
            template: "<div>x</div>",
            helpers: [
              %{
                "name" => "make_id",
                "args" => "",
                "code" => "\"id-\" <> random_id()"
              }
            ]
          },
          "Tier1A"
        )

      result = apply(module, :make_id, [])
      assert is_binary(result)
      assert String.starts_with?(result, "id-")
    end
  end

  describe "compiler edit — multi-clause helpers via repeated entries" do
    test "same-name helpers compile as multi-clause function" do
      module =
        compile_with(
          %{
            title: "with_multi_helpers",
            template: "<div>{classify(@x)}</div>",
            attrs: [%{name: "x", type: "string", opts: %{default: ""}}],
            helpers: [
              %{"name" => "classify", "args" => "\"a\"", "code" => "\"alpha\""},
              %{"name" => "classify", "args" => "\"b\"", "code" => "\"beta\""},
              %{
                "name" => "classify",
                "args" => "x when is_binary(x)",
                "code" => "\"other:\" <> x"
              }
            ]
          },
          "MultiHelper1"
        )

      assert apply(module, :classify, ["a"]) == "alpha"
      assert apply(module, :classify, ["b"]) == "beta"
      assert apply(module, :classify, ["zzz"]) == "other:zzz"
    end
  end

  describe "LV1.2 migration guard — rendered HTML of the TagEngine compile path" do
    test "single-clause template renders to exact HTML (pins compile_template_and_body / line 928)" do
      module =
        compile_with(
          %{
            title: "profile_card",
            attrs: [
              %{name: "name", type: "string", opts: %{required: true}},
              %{name: "wrap", type: "any", opts: %{default: nil}},
              %{name: "items", type: "any", opts: %{default: []}},
              %{name: "show", type: "boolean", opts: %{default: false}}
            ],
            template:
              ~S(<div class={@wrap}><h1>{@name}</h1><ul><li :for={i <- @items}>{i}</li></ul><span :if={@show}>ok</span></div>)
          },
          "SingleClauseRender"
        )

      html =
        module
        |> apply(:profile_card, [
          %{name: "Ann", wrap: "card", items: ["a", "b"], show: true, __changed__: nil}
        ])
        |> rendered_to_string()

      assert html ==
               ~S(<div class="card"><h1>Ann</h1><ul><li>a</li><li>b</li></ul><span>ok</span></div>)
    end

    test "the :if directive omits the element when false (pins directive rendering)" do
      module =
        compile_with(
          %{
            title: "gated",
            attrs: [%{name: "show", type: "boolean", opts: %{default: false}}],
            template: ~S(<div><span :if={@show}>ok</span></div>)
          },
          "GatedRender"
        )

      shown =
        module |> apply(:gated, [%{show: true, __changed__: nil}]) |> rendered_to_string()

      hidden =
        module |> apply(:gated, [%{show: false, __changed__: nil}]) |> rendered_to_string()

      assert shown == ~S(<div><span>ok</span></div>)
      assert hidden == ~S(<div></div>)
    end

    test "multi-clause dispatch renders distinct exact HTML per branch (pins compile_clause_template / line 553 + routing)" do
      module =
        compile_with(
          %{
            title: "icon_like",
            attrs: [
              %{name: "name", type: "string", opts: %{required: true}},
              %{name: "class", type: "any", opts: %{default: nil}},
              %{name: "rest", type: "global", opts: %{}}
            ],
            clauses: [
              %{
                "match" => "%{name: \"hero-\" <> _} = assigns",
                "body" => nil,
                "template" => "<span class={[@name, @class]} {@rest}/>"
              },
              %{
                "match" => nil,
                "body" => nil,
                "template" => "<span class={[\"unknown\", @class]} {@rest}>{@name}</span>"
              }
            ]
          },
          "MultiClauseRender"
        )

      hero =
        module
        |> apply(:icon_like, [%{name: "hero-bell", class: nil, rest: %{}, __changed__: nil}])
        |> rendered_to_string()

      other =
        module
        |> apply(:icon_like, [%{name: "fa-star", class: nil, rest: %{}, __changed__: nil}])
        |> rendered_to_string()

      assert hero == ~S(<span class="hero-bell"></span>)
      assert other == ~S(<span class="unknown ">fa-star</span>)
    end

    test "trim: true strips surrounding whitespace (pins the trim opt)" do
      module =
        compile_with(
          %{
            title: "trimmed",
            attrs: [%{name: "x", type: "string", opts: %{default: ""}}],
            template: "\n  <div>{@x}</div>\n"
          },
          "TrimRender"
        )

      html =
        module |> apply(:trimmed, [%{x: "hi", __changed__: nil}]) |> rendered_to_string()

      assert html == String.trim(html)
      assert html =~ "hi"
    end
  end
end
