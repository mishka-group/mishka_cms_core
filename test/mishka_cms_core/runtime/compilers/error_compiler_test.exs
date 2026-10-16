# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.ErrorCompilerTest do
  use ExUnit.Case, async: true
  alias MishkaCmsCore.Runtime.Compilers.ErrorCompiler
  @moduletag :unit

  describe "build_module/1" do
    test "builds complete module AST with minimal params" do
      params = %{
        title: "test_errors",
        error_module: TestModule.Errors,
        site: "test",
        error_pages: [
          %{status: 404, template: "<h1>Not Found</h1>"}
        ]
      }

      ast = ErrorCompiler.build_module(params)

      assert {:defmodule, _, [module_name, _]} = ast
      assert module_name == TestModule.Errors
    end

    test "builds module with all params including layouts and helpers" do
      params = %{
        title: "site_errors",
        error_module: TestModule.SiteErrors,
        site: "production",
        site_id: 1,
        host: "example.com",
        error_pages: [
          %{
            status: 404,
            template: ~S(<h1>Page Not Found</h1>),
            layout: %{template: ~S(<div class="error-layout"><%= @inner_content %></div>)}
          },
          %{status: 500, template: ~S(<h1>Server Error</h1>)}
        ],
        root_layout_template: ~S(
          <!DOCTYPE html>
          <html>
            <head><title>Error <%= @status %></title></head>
            <body><%= @inner_content %></body>
          </html>
        ),
        helpers: [
          %{
            name: "format_status",
            args: "status",
            code: "\"Error \" <> Integer.to_string(status)"
          }
        ]
      }

      ast = ErrorCompiler.build_module(params)

      assert {:defmodule, _, [module_name, [do: block]]} = ast
      assert module_name == TestModule.SiteErrors
      assert block != nil
    end

    test "handles params with string keys by atomizing them" do
      params = %{
        "title" => "test_errors",
        "error_module" => TestModule.StringKeyErrors,
        "site" => "test",
        "error_pages" => [
          %{"status" => 404, "template" => "<h1>Not Found</h1>"}
        ]
      }

      ast = ErrorCompiler.build_module(params)

      assert {:defmodule, _, _} = ast
    end
  end

  describe "build_error_information/1" do
    test "builds error information functions" do
      params = %{
        title: "error_info",
        error_module: TestModule.InfoErrors,
        id: "error-id-123",
        priority: 10,
        site: "test-site",
        site_id: "site-123",
        host: "example.com",
        format: :heex,
        path: "/errors",
        extra: %{custom: "metadata"},
        timestamp: ~U[2024-01-01 00:00:00Z],
        error_pages: [
          %{status: 404, template: "Not Found"}
        ]
      }

      {updated_params, [info_ast]} = ErrorCompiler.build_error_information(params)

      assert updated_params == params
      assert {:__block__, _, functions} = info_ast

      # Check that it contains the expected function definitions
      assert is_list(functions)
      assert length(functions) > 0
    end

    test "handles missing optional fields with defaults" do
      params = %{
        title: "minimal",
        error_module: TestModule.MinimalErrors,
        site: "test"
      }

      {updated_params, [info_ast]} = ErrorCompiler.build_error_information(params)

      assert updated_params == params
      assert {:__block__, _, _} = info_ast
    end
  end

  describe "build_layout_functions/1" do
    test "builds layout functions for error pages with layouts" do
      params = %{
        site: "test",
        error_pages: [
          %{
            status: 404,
            template: "Not Found",
            layout: %{template: ~S(<div class="layout"><%= @inner_content %></div>)}
          },
          %{
            status: 500,
            template: "Server Error",
            layout: %{template: ~S(<section><%= @inner_content %></section>)}
          }
        ]
      }

      {updated_params, functions_ast} = ErrorCompiler.build_layout_functions({params, []})

      assert updated_params == params
      # Should have 2 layout functions
      assert length(functions_ast) == 2
    end

    test "builds layout functions for error pages without layouts" do
      params = %{
        site: "test",
        error_pages: [
          %{status: 404, template: "Not Found"},
          %{status: 500, template: "Server Error"}
        ]
      }

      {updated_params, functions_ast} = ErrorCompiler.build_layout_functions({params, []})

      assert updated_params == params
      # Should still have 2 layout functions (default ones)
      assert length(functions_ast) == 2
    end

    test "handles empty error pages list" do
      params = %{site: "test"}

      {updated_params, functions_ast} = ErrorCompiler.build_layout_functions({params, []})

      assert updated_params == params
      assert functions_ast == []
    end

    test "handles mixed layouts (some with, some without)" do
      params = %{
        site: "test",
        error_pages: [
          %{
            status: 404,
            template: "Not Found",
            layout: %{template: ~S(<div><%= @inner_content %></div>)}
          },
          %{status: 500, template: "Server Error"},
          %{status: 403, template: "Forbidden"}
        ]
      }

      {updated_params, functions_ast} = ErrorCompiler.build_layout_functions({params, []})

      assert updated_params == params
      assert length(functions_ast) == 3
    end
  end

  describe "build_render_functions/1" do
    test "builds render functions for each error page" do
      params = %{
        site: "production",
        error_pages: [
          %{status: 404, template: "<h1>Not Found</h1>"},
          %{status: 500, template: "<h1>Server Error</h1>"},
          %{status: 403, template: "<h1>Forbidden</h1>"}
        ]
      }

      {updated_params, functions_ast} = ErrorCompiler.build_render_functions({params, []})

      assert updated_params == params
      # Should have 3 render functions + 1 catch-all
      assert length(functions_ast) == 4
    end

    test "adds catch-all render function" do
      params = %{
        site: "test",
        error_pages: [
          %{status: 404, template: "Not Found"}
        ]
      }

      {updated_params, functions_ast} = ErrorCompiler.build_render_functions({params, []})

      assert updated_params == params
      # 1 specific render + 1 catch-all
      assert length(functions_ast) == 2

      # Check that catch-all function is present
      catch_all_ast = List.last(functions_ast)
      ast_string = Macro.to_string(catch_all_ast)
      assert ast_string =~ "Logger.warning"
      assert ast_string =~ "Plug.Conn.Status.reason_phrase"
    end

    test "handles empty error pages list" do
      params = %{site: "test"}

      {updated_params, functions_ast} = ErrorCompiler.build_render_functions({params, []})

      assert updated_params == params
      # Should have just the catch-all
      assert length(functions_ast) == 1
    end

    test "render functions include site in warning message" do
      params = %{
        site: "my-special-site",
        error_pages: []
      }

      {_, functions_ast} = ErrorCompiler.build_render_functions({params, []})

      catch_all_ast = List.last(functions_ast)
      ast_string = Macro.to_string(catch_all_ast)
      assert ast_string =~ "my-special-site"
    end
  end

  describe "build_helpers/1" do
    test "builds helper functions" do
      params = %{
        site: "test",
        helpers: [
          %{
            name: "format_error",
            args: "status",
            code: "\"Error: \" <> Integer.to_string(status)"
          },
          %{
            name: "error_class",
            args: "status",
            code: "\"error-\" <> Integer.to_string(status)"
          }
        ]
      }

      {updated_params, functions_ast} = ErrorCompiler.build_helpers({params, []})

      assert updated_params == params
      # 2 helpers + 1 root_layout
      assert length(functions_ast) == 3
    end

    test "builds root layout with custom template" do
      params = %{
        site: "test",
        root_layout_template: ~S(
          <!DOCTYPE html>
          <html lang="en">
            <head>
              <title>Custom Error <%= @status %></title>
            </head>
            <body class="error-page">
              <%= @inner_content %>
            </body>
          </html>
        )
      }

      {updated_params, functions_ast} = ErrorCompiler.build_helpers({params, []})

      assert updated_params == params
      # Just the root_layout function
      assert length(functions_ast) == 1

      root_layout_ast = List.last(functions_ast)
      ast_string = Macro.to_string(root_layout_ast)
      assert ast_string =~ "root_layout"
    end

    test "builds default root layout when no template provided" do
      params = %{site: "test"}

      {updated_params, functions_ast} = ErrorCompiler.build_helpers({params, []})

      assert updated_params == params
      # Just the default root_layout
      assert length(functions_ast) == 1

      root_layout_ast = List.last(functions_ast)
      ast_string = Macro.to_string(root_layout_ast)
      assert ast_string =~ "root_layout"
      assert ast_string =~ "~H"
    end

    test "builds helper with multiple arguments" do
      params = %{
        site: "test",
        helpers: [
          %{
            name: "format_error_message",
            args: "{status, message}",
            code: "\"Error \" <> Integer.to_string(status) <> \": \" <> message"
          }
        ]
      }

      {updated_params, functions_ast} = ErrorCompiler.build_helpers({params, []})

      assert updated_params == params
      # 1 helper + 1 root_layout
      assert length(functions_ast) == 2
    end

    test "handles empty helpers list" do
      params = %{site: "test", helpers: []}

      {updated_params, functions_ast} = ErrorCompiler.build_helpers({params, []})

      assert updated_params == params
      # Just the root_layout
      assert length(functions_ast) == 1
    end
  end

  describe "build_helpers/1 argument lists" do
    # COMPILED AND CALLED, the way a page's helpers are (`LiveViewCompiler.helper_args/1`).
    test "a helper takes the arguments its args name: none, one or two" do
      params = %{
        site: "test",
        helpers: [
          %{name: "none", args: "", code: ":none"},
          %{name: "blank", args: "  ", code: ":blank"},
          %{name: "unset", args: nil, code: ":unset"},
          %{name: "one", args: "name", code: "{:one, name}"},
          %{name: "two", args: "first, second", code: "{:two, first, second}"},
          %{name: "defaulted", args: "first, second \\\\ :b", code: "{first, second}"}
        ]
      }

      module = compiled_helpers!(params)

      assert module.none() == :none
      assert module.blank() == :blank
      assert module.unset() == :unset
      assert module.one(:a) == {:one, :a}
      assert module.two(:a, :b) == {:two, :a, :b}
      assert module.defaulted(:a) == {:a, :b}
      refute function_exported?(module, :none, 1)
      refute function_exported?(module, :two, 1)
    end
  end

  defp compiled_helpers!(params) do
    {_params, functions_ast} = ErrorCompiler.build_helpers({params, []})
    # `root_layout/1` is the error page's own, and needs the HEEx engine a bare module has not.
    helpers = Enum.reject(functions_ast, &defines?(&1, :root_layout))
    module = Module.concat(__MODULE__, "Helpers#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          unquote({:__block__, [], helpers})
        end
      end
    )

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    module
  end

  defp defines?({:def, _meta, [{:when, _, [{name, _, _} | _]} | _]}, name), do: true
  defp defines?({:def, _meta, [{name, _, _} | _]}, name), do: true
  defp defines?(_ast, _name), do: false

  describe "create_module_ast/1" do
    test "creates complete module AST" do
      params = %{
        error_module: TestModule.FinalErrors
      }

      functions_ast = [
        quote do
          def test_function(), do: "test"
        end
      ]

      module_ast = ErrorCompiler.create_module_ast({params, functions_ast})

      assert {:defmodule, _, [module_alias, [do: {:__block__, _, body}]]} = module_ast
      assert module_alias == TestModule.FinalErrors

      # Check for required imports
      assert Enum.any?(body, fn
               {:require, _, [{:__aliases__, _, [:Logger]}]} -> true
               _ -> false
             end)
    end
  end

  describe "make_env/0" do
    test "creates environment with proper imports" do
      env = ErrorCompiler.make_env()

      assert %Macro.Env{} = env
      # The function should create an environment with Phoenix imports
      assert is_list(env.functions)
    end
  end

  describe "integration tests" do
    test "compiles a simple error page module" do
      params = %{
        title: "simple_errors",
        error_module: TestIntegration.SimpleErrors,
        site: "test",
        error_pages: [
          %{
            status: 404,
            template: ~S(<h1>Page Not Found</h1><p>The page you requested doesn't exist.</p>)
          },
          %{status: 500, template: ~S(<h1>Internal Server Error</h1><p>Something went wrong.</p>)}
        ]
      }

      ast = ErrorCompiler.build_module(params)

      # Verify the AST structure
      assert {:defmodule, _, [module_name, _]} = ast
      assert module_name == TestIntegration.SimpleErrors

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "__error_information__"
      assert formatted =~ "render"
      assert formatted =~ "layout"
      assert formatted =~ "root_layout"
    end

    test "compiles error pages with custom layouts" do
      params = %{
        title: "layout_errors",
        error_module: TestIntegration.LayoutErrors,
        site: "production",
        error_pages: [
          %{
            status: 404,
            template: ~S|<h1><%= format_title("Not Found") %></h1>|,
            layout: %{
              template: ~S'''
              <div class="error-container">
                <div class="error-content">
                  <%= @inner_content %>
                </div>
                <a href="/">Go Home</a>
              </div>
              '''
            }
          },
          %{
            status: 500,
            template: ~S(<h1>Server Error</h1>),
            layout: %{
              template: ~S(<section class="error"><%= @inner_content %></section>)
            }
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

      ast = ErrorCompiler.build_module(params)

      assert {:defmodule, _, _} = ast

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "format_title"
      assert formatted =~ "layout(404"
      assert formatted =~ "layout(500"
    end

    test "compiles with custom root layout" do
      params = %{
        title: "custom_root",
        error_module: TestIntegration.CustomRootErrors,
        site: "test",
        error_pages: [
          %{status: 404, template: ~S(<h1>Not Found</h1>)}
        ],
        root_layout_template: ~S'''
        <!DOCTYPE html>
        <html lang="en" class="h-full">
          <head>
            <meta charset="utf-8">
            <title>Error <%= @status %> - My Site</title>
            <meta name="viewport" content="width=device-width, initial-scale=1">
          </head>
          <body class="h-full">
            <div id="app" class="min-h-full">
              <%= @inner_content %>
            </div>
          </body>
        </html>
        '''
      }

      ast = ErrorCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "root_layout"
      # The template is compiled, so check for the key parts
      assert formatted =~ "status" || formatted =~ ":status"
      assert formatted =~ "inner_content"
    end

    test "handles all standard HTTP error status codes" do
      params = %{
        title: "all_errors",
        error_module: TestIntegration.AllErrors,
        site: "test",
        error_pages: [
          %{status: 400, template: ~S(<h1>Bad Request</h1>)},
          %{status: 401, template: ~S(<h1>Unauthorized</h1>)},
          %{status: 403, template: ~S(<h1>Forbidden</h1>)},
          %{status: 404, template: ~S(<h1>Not Found</h1>)},
          %{status: 422, template: ~S(<h1>Unprocessable Entity</h1>)},
          %{status: 500, template: ~S(<h1>Internal Server Error</h1>)},
          %{status: 502, template: ~S(<h1>Bad Gateway</h1>)},
          %{status: 503, template: ~S(<h1>Service Unavailable</h1>)}
        ]
      }

      ast = ErrorCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check for each status code
      assert formatted =~ "render(var!(conn), 400)"
      assert formatted =~ "render(var!(conn), 401)"
      assert formatted =~ "render(var!(conn), 403)"
      assert formatted =~ "render(var!(conn), 404)"
      assert formatted =~ "render(var!(conn), 422)"
      assert formatted =~ "render(var!(conn), 500)"
      assert formatted =~ "render(var!(conn), 502)"
      assert formatted =~ "render(var!(conn), 503)"
    end

    test "compiles with complex helper functions" do
      params = %{
        title: "helper_errors",
        error_module: TestIntegration.HelperErrors,
        site: "test",
        error_pages: [
          %{
            status: 404,
            # Inner error templates compile with the HEEx TagEngine (so `<.component>`/hooks work), so
            # dynamic attributes use `{...}` rather than classic `<%= %>` interpolation.
            template: ~S'''
            <div class={error_class(@status)}>
              <h1>{format_status(@status)}</h1>
              <p>{error_message(@status)}</p>
            </div>
            '''
          }
        ],
        helpers: [
          %{
            name: "error_class",
            args: "status",
            code: """
            case status do
              404 -> "error-not-found"
              500 -> "error-server"
              _ -> "error-generic"
            end
            """
          },
          %{
            name: "format_status",
            args: "status",
            code: "\"Error \" <> Integer.to_string(status)"
          },
          %{
            name: "error_message",
            args: "status",
            code: """
            case status do
              404 -> "The page you're looking for doesn't exist."
              500 -> "An internal server error occurred."
              _ -> "An error occurred."
            end
            """
          }
        ]
      }

      ast = ErrorCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "error_class"
      assert formatted =~ "format_status"
      assert formatted =~ "error_message"
    end

    test "compiles with metadata and extra information" do
      params = %{
        title: "metadata_errors",
        error_module: TestIntegration.MetadataErrors,
        site: "production",
        site_id: 123,
        host: "example.com",
        id: "error-page-456",
        priority: 100,
        path: "/custom-errors",
        extra: %{
          version: "1.0.0",
          category: "public",
          tags: ["error", "custom"]
        },
        timestamp: ~U[2024-01-15 10:00:00Z],
        error_pages: [
          %{status: 404, template: "Not Found"}
        ]
      }

      ast = ErrorCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check metadata is included
      assert formatted =~ "error-page-456"
      assert formatted =~ "production"
      assert formatted =~ "example.com"
      assert formatted =~ "version"
      assert formatted =~ "category"
    end

    test "handles minimal input gracefully" do
      params = %{
        title: "minimal",
        error_module: TestIntegration.MinimalErrors,
        site: "test"
      }

      # Should still generate AST with catch-all
      ast = ErrorCompiler.build_module(params)
      assert {:defmodule, _, _} = ast

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      # Should have catch-all render function
      assert formatted =~ "render(var!(conn), var!(status))"
      assert formatted =~ "Plug.Conn.Status.reason_phrase"
    end

    test "compiles error page with conditional rendering" do
      params = %{
        title: "conditional_errors",
        error_module: TestIntegration.ConditionalErrors,
        site: "test",
        error_pages: [
          %{
            status: 404,
            template: ~S'''
            <div>
              <h1>404 - Not Found</h1>
              <%= if @conn.assigns[:current_user] do %>
                <p>Even logged in users can't find this page!</p>
              <% else %>
                <p>This page doesn't exist. Please <a href="/login">login</a> or go <a href="/">home</a>.</p>
              <% end %>
            </div>
            '''
          }
        ]
      }

      ast = ErrorCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "404"
      assert formatted =~ "@conn"
    end

    test "compiles with nested layouts" do
      params = %{
        title: "nested_layout_errors",
        error_module: TestIntegration.NestedLayoutErrors,
        site: "test",
        error_pages: [
          %{
            status: 404,
            template: ~S(<h1>Not Found</h1><p>Sorry!</p>),
            layout: %{
              template: ~S'''
              <div class="error-wrapper">
                <div class="error-icon">❌</div>
                <div class="error-content">
                  <%= @inner_content %>
                </div>
              </div>
              '''
            }
          }
        ],
        root_layout_template: ~S'''
        <!DOCTYPE html>
        <html>
          <head>
            <title>Error</title>
            <style>
              .error-wrapper { padding: 2rem; }
              .error-icon { font-size: 3rem; }
            </style>
          </head>
          <body>
            <%= @inner_content %>
          </body>
        </html>
        '''
      }

      ast = ErrorCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "layout(404"
      assert formatted =~ "root_layout"
      assert formatted =~ "@inner_content"
    end
  end
end
