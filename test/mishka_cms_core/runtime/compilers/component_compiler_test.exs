# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.ComponentCompilerTest do
  use ExUnit.Case, async: true
  alias MishkaCmsCore.Runtime.Compilers.ComponentCompiler
  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler
  @moduletag :unit

  # The name of a synthetic total catch-all (`def fn(_, …), do: ""`) that build_helpers injects, or nil.
  defp catchall_name({:def, _, [{name, _, args}, [do: ""]]})
       when is_atom(name) and is_list(args) do
    if args != [] and Enum.all?(args, &match?({:_, _, _}, &1)), do: to_string(name), else: nil
  end

  defp catchall_name(_), do: nil

  defp catchall_names(component) do
    helpers =
      Enum.map(component["helpers"] || [], fn h ->
        Map.new(h, fn {k, v} -> {String.to_atom(k), v} end)
      end)

    {_p, asts} = ComponentCompiler.build_helpers({%{helpers: helpers}, []})
    asts |> Enum.map(&catchall_name/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  describe "build_module/1" do
    test "builds complete module AST with minimal params" do
      params = %{
        title: "test_component",
        component_module: TestModule.Component,
        template: ~S(<div>Hello</div>)
      }

      ast = ComponentCompiler.build_module(params)

      assert {:defmodule, _, [_module_name, _]} = ast
    end

    test "builds module with all params including attrs, slots, and helpers" do
      params = %{
        title: "card",
        component_module: TestModule.Card,
        template: ~S(<div class={@class}><%= @title %></div>),
        attrs: [
          %{name: "class", type: "string", opts: %{default: "card"}},
          %{name: "title", type: "string", opts: %{required: true}}
        ],
        slots: [
          %{name: "inner_block", opts: %{required: true}, attrs: []}
        ],
        helpers: [
          %{
            name: "format_title",
            args: "title",
            code: "String.upcase(title)"
          }
        ]
      }

      ast = ComponentCompiler.build_module(params)

      assert {:defmodule, _, [_module_name, [do: block]]} = ast
      assert block != nil
    end

    test "handles params with string keys by atomizing them" do
      params = %{
        "title" => "test_component",
        "component_module" => TestModule.Component,
        "template" => ~S(<div>Hello</div>)
      }

      ast = ComponentCompiler.build_module(params)

      assert {:defmodule, _, _} = ast
    end
  end

  describe "build_component_information/1" do
    test "builds component information functions" do
      params = %{
        title: "test_info",
        component_module: TestModule.InfoComponent,
        id: "test-id-123",
        priority: 5,
        site: "test-site",
        site_id: "site-123",
        host: "example.com",
        format: :heex,
        permissions: ["view", "edit"],
        extra: %{custom: "data"},
        timestamp: ~U[2024-01-01 00:00:00Z]
      }

      {updated_params, [info_ast]} = ComponentCompiler.build_component_information(params)

      assert updated_params == params
      assert {:__block__, _, functions} = info_ast

      # Check that it contains the expected function definitions
      # The functions list contains multiple def statements for __component_information__
      assert is_list(functions)
      assert length(functions) > 0
    end

    test "handles missing optional fields with defaults" do
      params = %{
        title: "minimal",
        component_module: TestModule.Minimal
      }

      {updated_params, [info_ast]} = ComponentCompiler.build_component_information(params)

      assert updated_params == params
      assert {:__block__, _, _} = info_ast
    end
  end

  describe "build_attributes/1" do
    test "builds attribute declarations" do
      params = %{
        attrs: [
          %{name: "class", type: "string", opts: %{default: ""}},
          %{name: "count", type: "integer", opts: %{default: 0}},
          %{name: "active", type: "boolean", opts: %{required: true}}
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_attributes({params, []})

      assert updated_params == params
      # setup + 3 attrs + 2 synthetic attrs (:site, :component_name)
      assert length(functions_ast) == 6
    end

    test "handles global attributes with rest" do
      params = %{
        attrs: [
          %{name: "rest", type: "global", opts: %{include: ["class", "id"]}}
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_attributes({params, []})

      assert updated_params == params
      # setup + rest attr + 2 synthetic attrs (:site, :component_name)
      assert length(functions_ast) == 4
    end

    test "handles struct type attributes" do
      params = %{
        attrs: [
          %{name: "user", type: "struct", struct_name: "User", opts: %{}}
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_attributes({params, []})

      assert updated_params == params
      # setup + user attr + 2 synthetic attrs (:site, :component_name)
      assert length(functions_ast) == 4
    end

    test "filters invalid attribute options" do
      params = %{
        attrs: [
          %{
            name: "test",
            type: "string",
            opts: %{
              default: "value",
              required: false,
              invalid_option: "should be removed",
              another_invalid: true
            }
          }
        ]
      }

      {_, functions_ast} = ComponentCompiler.build_attributes({params, []})

      # The invalid options should be filtered out
      # setup + 1 attr + 2 synthetic attrs (:site, :component_name)
      assert length(functions_ast) == 4
    end

    test "handles empty attrs list" do
      params = %{}

      {updated_params, functions_ast} = ComponentCompiler.build_attributes({params, []})

      assert updated_params == params
      # setup + 2 synthetic attrs (:site, :component_name)
      assert length(functions_ast) == 3
    end
  end

  describe "build_slots/1" do
    test "builds slot declarations" do
      params = %{
        slots: [
          %{name: "inner_block", opts: %{required: true}, attrs: []},
          %{name: "footer", opts: %{doc: "Footer content"}, attrs: []}
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_slots({params, []})

      assert updated_params == params
      # setup + 2 slots
      assert length(functions_ast) == 3
    end

    test "builds slots with nested attributes" do
      params = %{
        slots: [
          %{
            name: "item",
            opts: %{},
            attrs: [
              %{name: "title", type: "string", opts: %{required: true}},
              %{name: "icon", type: "string", opts: %{default: nil}}
            ]
          }
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_slots({params, []})

      assert updated_params == params
      # setup + 1 slot with nested attrs
      assert length(functions_ast) == 2
    end

    test "filters invalid slot options" do
      params = %{
        slots: [
          %{
            name: "content",
            opts: %{
              required: true,
              validate_attrs: true,
              doc: "Content slot",
              invalid_option: "should be removed"
            },
            attrs: []
          }
        ]
      }

      {_, functions_ast} = ComponentCompiler.build_slots({params, []})

      # setup + 1 slot
      assert length(functions_ast) == 2
    end

    test "handles empty slots list" do
      params = %{}

      {updated_params, functions_ast} = ComponentCompiler.build_slots({params, []})

      assert updated_params == params
      # just setup
      assert length(functions_ast) == 1
    end
  end

  describe "build_component_function/1" do
    test "builds component function with template" do
      params = %{
        title: "button",
        template: ~S(<button class={@class}><%= @label %></button>),
        attrs: [
          %{name: "class", type: "string", opts: %{default: "btn"}},
          %{name: "label", type: "string", opts: %{default: "Click"}}
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_component_function({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1

      # ONE def, NOT TWO. There used to be a `render(name, assigns)` alias beside the component's own
      # function — the same body a second time, with the name as its first argument. Nothing in the
      # tree ever called it: a page reaches a component through `LiveViewHelpers.component/1`, which
      # applies the title as a function name, and the error-page compiler's `render/2` is a different
      # module entirely. It was emitted into all 141 compiled component modules.
      [{:def, _meta, [{:button, _, _args}, _body]}] = functions_ast
    end

    test "builds component function with body code" do
      params = %{
        title: "computed",
        template: ~S(<div><%= @result %></div>),
        body: "assigns = Map.put(assigns, :result, \"computed\")"
      }

      {updated_params, functions_ast} = ComponentCompiler.build_component_function({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end

    test "handles empty template" do
      params = %{
        title: "empty",
        template: ""
      }

      {updated_params, functions_ast} = ComponentCompiler.build_component_function({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end

    test "merges default values from attributes" do
      params = %{
        title: "defaults",
        template: ~S(<div><%= @value %></div>),
        attrs: [
          %{name: "value", type: "string", opts: %{default: "default"}},
          %{name: "rest", type: "global", opts: %{}}
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_component_function({params, []})

      assert updated_params == params
      # The function should include default value merging
      assert length(functions_ast) == 1
    end
  end

  describe "build_helpers/1" do
    test "builds helper functions" do
      params = %{
        helpers: [
          %{
            name: "format_date",
            args: "date",
            code: "Calendar.strftime(date, \"%Y-%m-%d\")"
          },
          %{
            name: "capitalize",
            args: "text",
            code: "String.capitalize(text)"
          }
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_helpers({params, []})

      assert updated_params == params
      assert length(functions_ast) == 2
    end

    test "appends a total catch-all so a narrowed dispatcher tolerates a dropped combo" do
      # A NARROWED color_variant: only the nil/natural clause + Chelekom's is_binary fallback survived
      # (install-time narrowing dropped the nil/primary clause). Without a total catch-all,
      # color_variant(nil, "primary") raises FunctionClauseError — the real-world crash on login.
      params = %{
        helpers: [
          %{
            name: "color_variant",
            args: ~s(nil, "natural"),
            code: ~s(["ring-natural"]),
            discriminators: [%{"axis" => "color", "values" => ["natural"]}]
          },
          %{
            name: "color_variant",
            args: "params, _ when is_binary(params)",
            code: "params",
            discriminators: []
          }
        ]
      }

      {_params, functions_ast} = ComponentCompiler.build_helpers({params, []})

      {{:module, mod, _, _}, _} =
        Code.eval_quoted(
          quote do
            defmodule TotalCatchAllDispatcherTest do
              (unquote_splicing(functions_ast))
            end
          end
        )

      # The dropped combo renders bare instead of crashing.
      assert mod.color_variant(nil, "primary") == ""
      assert mod.color_variant(nil, nil) == ""
      # The kept clause + Chelekom's binary fallback are untouched.
      assert mod.color_variant(nil, "natural") == ["ring-natural"]
      assert mod.color_variant("custom", "x") == "custom"
    end

    test "does NOT add a catch-all to non-dispatcher helpers (no discriminators)" do
      # Single-clause helper + a multi-clause helper WITHOUT discriminators must be left untouched, so
      # a helper that legitimately returns a non-class value is never masked with "".
      params = %{
        helpers: [
          %{name: "format_date", args: "date", code: "to_string(date)"},
          %{name: "render_kind", args: "%{kind: :a} = assigns", code: "assigns"},
          %{name: "render_kind", args: "%{kind: :b} = assigns", code: "assigns"}
        ]
      }

      {_params, functions_ast} = ComponentCompiler.build_helpers({params, []})

      # 3 clauses in, 3 out — no synthetic catch-all injected.
      assert length(functions_ast) == 3
    end

    test "a REAL component compiles via the full pipeline and tolerates unknown combos (all arities)" do
      # Strongest end-to-end check: real bundle component → build_module → compile_module (with the
      # proper `use Phoenix.Component` context) → call its dispatchers with combos that don't exist.
      bundle = UiKitHandler.ensure_bundle!()
      comp = Enum.find(bundle["components"], &(&1["name"] == "chelekom-card"))
      extra = comp["extra"] || %{}

      params = %{
        id: "cct-card",
        title: comp["name"],
        component_module: __MODULE__.RealCard,
        template: comp["template"],
        body: comp["body"],
        attrs: comp["attrs"],
        slots: comp["slots"],
        helpers:
          Enum.map(comp["helpers"] || [], fn h ->
            Map.new(h, fn {k, v} -> {String.to_atom(k), v} end)
          end),
        format: comp["format"],
        priority: comp["priority"],
        permissions: comp["permissions"],
        extra: extra,
        prelude: extra["prelude"],
        module_attributes: extra["module_attributes"] || [],
        clauses: extra["clauses"] || []
      }

      ast = ComponentCompiler.build_module(params)
      {:ok, mod, _diags} = MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

      # arity-1 (size_class) and arity-2 (color_variant) dispatchers both render bare, never crash.
      assert mod.size_class(nil) == ""
      assert mod.color_variant(nil, "definitely-not-a-real-color") == ""
    end

    # A kit exporter cannot write `%{kind: :banner}` into JSON, so it emits
    # `%{"__atom_map__" => [[":kind", "banner"]]}` — atoms tagged with a `:` sentinel — and leaves the
    # consumer to rebuild the real map at compile time. This is that rebuild. Without it the envelope
    # itself reached the component as the attribute's value, and the first thing that interpolated it
    # raised `String.Chars not implemented for Map`.
    test "an __atom_map__ default is rebuilt as a real atom-keyed map" do
      params = %{
        title: "atom_map_default",
        component_module: AtomMapDefault.Component,
        template: ~S[<div>{inspect(@params)}{inspect(@plain)}</div>],
        attrs: [
          %{
            name: "params",
            type: "map",
            opts: %{"default" => %{"__atom_map__" => [[":kind", "banner"], [":size", ":large"]]}}
          },
          %{name: "plain", type: "string", opts: %{"default" => "untouched"}}
        ]
      }

      ast = ComponentCompiler.build_module(params)
      {:ok, mod, _diags} = MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

      html =
        %{}
        |> mod.atom_map_default()
        |> Phoenix.HTML.Safe.to_iodata()
        |> IO.iodata_to_binary()

      # Atom KEYS, and the `:` sentinel decoded back into an atom VALUE too. Asserted per-entry
      # because map ordering is not part of the contract.
      assert html =~ ~s(kind: &quot;banner&quot;)
      assert html =~ ~s(size: :large)
      refute html =~ "__atom_map__"
      # A default that is not an envelope is passed through untouched.
      assert html =~ ~s(untouched)
    end

    test "EVERY dispatcher family in the real Chelekom bundle gets a total catch-all (no type missed)" do
      bundle = UiKitHandler.ensure_bundle!()

      find = fn name -> Enum.find(bundle["components"], &(&1["name"] == name)) end

      # card exercises six different dispatcher families — each must get a fallback.
      card = catchall_names(find.("chelekom-card"))

      for fname <-
            ~w(color_variant size_class rounded_size space_class padding_size wrapper_padding) do
        assert fname in card, "card is missing a total catch-all for #{fname}/n"
      end

      # arity coverage: color_variant/3 (tel_field) and arity-1 layout dispatchers (flex).
      assert "color_variant" in catchall_names(find.("chelekom-tel-field"))

      flex = catchall_names(find.("chelekom-flex"))
      for fname <- ~w(direction_class justify_class align_class), do: assert(fname in flex)

      # Broadly: hundreds of dispatchers across the whole kit get a fallback — nothing slipped through.
      total = bundle["components"] |> Enum.map(&MapSet.size(catchall_names(&1))) |> Enum.sum()
      assert total > 200
    end

    test "builds helper with multiple arguments" do
      params = %{
        helpers: [
          %{
            name: "combine",
            args: "{first, second}",
            code: "first <> \", \" <> second"
          }
        ]
      }

      {updated_params, functions_ast} = ComponentCompiler.build_helpers({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end

    test "handles empty helpers list" do
      params = %{}

      {updated_params, functions_ast} = ComponentCompiler.build_helpers({params, []})

      assert updated_params == params
      assert functions_ast == []
    end
  end

  describe "create_module_ast/1" do
    test "creates complete module AST" do
      params = %{
        component_module: TestModule.FinalComponent
      }

      functions_ast = [
        quote do
          def test_function, do: "test"
        end
      ]

      module_ast = ComponentCompiler.create_module_ast({params, functions_ast})

      assert {:defmodule, _, [module_alias, [do: {:__block__, _, body}]]} = module_ast
      assert module_alias == TestModule.FinalComponent

      # Check for required imports
      assert Enum.any?(body, fn
               {:import, _, [{:__aliases__, _, [:Phoenix, :Component, :Declarative]}]} -> true
               _ -> false
             end)
    end
  end

  describe "make_env/0" do
    test "creates environment with proper imports" do
      env = ComponentCompiler.make_env()

      assert %Macro.Env{} = env
      # The function should create an environment with Phoenix imports
      assert is_list(env.functions)
    end
  end

  describe "integration tests" do
    test "compiles and executes a simple component" do
      params = %{
        title: "greeting",
        component_module: TestIntegration.GreetingComponent,
        template: ~S(<div class={@class}>Hello, <%= @name %>!</div>),
        attrs: [
          %{name: "name", type: "string", opts: %{default: "World"}},
          %{name: "class", type: "string", opts: %{default: "greeting"}}
        ]
      }

      ast = ComponentCompiler.build_module(params)

      # Verify the AST structure
      assert {:defmodule, _, [module_name, _]} = ast
      assert module_name == TestIntegration.GreetingComponent

      # Use ast_to_format_string! for better inspection
      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      assert formatted =~ "__component_information__"
      assert formatted =~ "greeting"
      assert formatted =~ "assigns"
    end

    test "compiles component with slots and helpers" do
      params = %{
        title: "card",
        component_module: TestIntegration.CardComponent,
        template: ~S'''
        <div class={@class}>
          <h3><%= format_title(@title) %></h3>
          <%= render_slot(@inner_block) %>
          <div :if={@footer}>
            <%= render_slot(@footer) %>
          </div>
        </div>
        ''',
        attrs: [
          %{name: "title", type: "string", opts: %{required: true}},
          %{name: "class", type: "string", opts: %{default: "card"}},
          %{name: "footer", type: "boolean", opts: %{default: false}}
        ],
        slots: [
          %{name: "inner_block", opts: %{required: true}, attrs: []},
          %{
            name: "footer",
            opts: %{},
            attrs: [
              %{name: "class", type: "string", opts: %{default: "footer"}}
            ]
          }
        ],
        helpers: [
          %{
            name: "format_title",
            args: "title",
            code: "String.upcase(title)"
          }
        ]
      }

      ast = ComponentCompiler.build_module(params)

      # This should compile without errors
      assert {:defmodule, _, _} = ast

      # Skip Code.format_string! roundtrip: Elixir 1.19's Macro.to_string
      # emits anonymous-fn-call+do-block as `slot. :foo, [] do … end`, which
      # the formatter then rejects as a syntax error. Substring checks below
      # don't need the formatted form.
      formatted = Macro.to_string(ast)
      assert formatted =~ "format_title"
      assert formatted =~ "render_slot"
      assert formatted =~ "inner_block"
    end

    test "handles component with body code execution" do
      params = %{
        title: "computed_value",
        component_module: TestIntegration.ComputedComponent,
        template: ~S(<div>Result: <%= @computed %></div>),
        body: """
        computed = (@base * 2) + 10
        assigns = Map.put(assigns, :computed, computed)
        """,
        attrs: [
          %{name: "base", type: "integer", opts: %{default: 5}}
        ]
      }

      ast = ComponentCompiler.build_module(params)

      # The AST should include the body code
      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "computed"
      assert formatted =~ "base"
    end

    test "handles all supported attribute types" do
      params = %{
        title: "types_test",
        component_module: TestIntegration.TypesComponent,
        template: ~S(<div>Types Test</div>),
        attrs: [
          %{name: "any_type", type: "any", opts: %{}},
          %{name: "string_type", type: "string", opts: %{default: "text"}},
          %{name: "atom_type", type: "atom", opts: %{default: :default}},
          %{name: "boolean_type", type: "boolean", opts: %{default: false}},
          %{name: "integer_type", type: "integer", opts: %{default: 0}},
          %{name: "float_type", type: "float", opts: %{default: 0.0}},
          %{name: "list_type", type: "list", opts: %{default: []}},
          %{name: "map_type", type: "map", opts: %{default: %{}}},
          %{name: "global_type", type: "global", opts: %{}},
          %{name: "struct_type", type: "struct", struct_name: "DateTime", opts: %{}}
        ]
      }

      ast = ComponentCompiler.build_module(params)

      # Should handle all types without errors
      assert {:defmodule, _, _} = ast

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      # Check that attribute types are properly handled

      assert formatted =~ ":string"
      assert formatted =~ ":atom"
      assert formatted =~ ":boolean"
      assert formatted =~ ":integer"
      assert formatted =~ ":float"
      assert formatted =~ ":list"
      assert formatted =~ ":map"
      assert formatted =~ ":global"
      assert formatted =~ "DateTime"
    end

    test "handles component with complex HEEx template" do
      params = %{
        title: "complex_template",
        component_module: TestIntegration.ComplexComponent,
        template: ~S'''
        <div class={["container", @class]} id={@id}>
          <%= for item <- @items do %>
            <div class="item">
              <span><%= item.name %></span>
              <span :if={item.price}><%= item.price %></span>
            </div>
          <% end %>

          <div :if={@show_footer} class="footer">
            <%= render_slot(@footer, %{timestamp: DateTime.utc_now()}) %>
          </div>
        </div>
        ''',
        attrs: [
          %{name: "id", type: "string", opts: %{required: true}},
          %{name: "class", type: "string", opts: %{default: ""}},
          %{name: "items", type: "list", opts: %{default: []}},
          %{name: "show_footer", type: "boolean", opts: %{default: false}}
        ],
        slots: [
          %{
            name: "footer",
            opts: %{},
            attrs: [
              %{name: "timestamp", type: "any", opts: %{}}
            ]
          }
        ]
      }

      ast = ComponentCompiler.build_module(params)

      # Should compile complex template without errors
      assert {:defmodule, _, _} = ast

      # Skip Code.format_string! roundtrip — see "compiles component with slots
      # and helpers" above for the Elixir 1.19 regression note.
      formatted = Macro.to_string(ast)
      # The template is compiled, check for key elements
      assert formatted =~ "items"
      assert formatted =~ "show_footer"
      assert formatted =~ "render_slot"
    end

    test "handles component with metadata and permissions" do
      params = %{
        title: "secure_component",
        component_module: TestIntegration.SecureComponent,
        template: ~S(<div>Secure Content</div>),
        id: "comp-123",
        site: "main-site",
        site_id: "site-456",
        host: "example.com",
        priority: 10,
        permissions: ["admin:dashboard:runtime:page", "admin:dashboard:runtime:layout"],
        extra: %{
          category: "admin",
          version: "1.0.0"
        },
        timestamp: ~U[2024-01-15 10:00:00Z]
      }

      ast = ComponentCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check metadata is included
      assert formatted =~ "comp-123"
      assert formatted =~ "main-site"
      assert formatted =~ "admin:dashboard:runtime:page"
      assert formatted =~ "category"
      assert formatted =~ "version"
    end

    test "handles malformed input gracefully" do
      # Minimal params with title
      params = %{
        title: "error_component",
        component_module: TestIntegration.ErrorComponent
      }

      # Should still generate AST, even if incomplete
      ast = ComponentCompiler.build_module(params)
      assert {:defmodule, _, _} = ast
    end
  end
end
