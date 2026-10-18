# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.LayoutCompilerTest do
  use ExUnit.Case, async: true
  alias MishkaCmsCore.Runtime.Compilers.LayoutCompiler
  @moduletag :unit

  describe "build_module/1" do
    test "builds complete module AST with minimal params" do
      params = %{
        title: "test_layout",
        layout_module: TestModule.Layout,
        template: ~S(<html><body><%= @inner_content %></body></html>)
      }

      ast = LayoutCompiler.build_module(params)

      assert {:defmodule, _, [_module_name, _]} = ast
    end

    test "builds module with all params including helpers and resources" do
      params = %{
        title: "main_layout",
        layout_module: TestModule.MainLayout,
        template: ~S"""
        <!DOCTYPE html>
        <html>
          <head>
            <title><%= @title %></title>
            <%= for link <- @resource_links do %>
              <link rel={link.rel} href={link.href}>
            <% end %>
          </head>
          <body><%= @inner_content %></body>
        </html>
        """,
        resource_links: [
          %{rel: "stylesheet", href: "/assets/app.css", type: "text/css"},
          %{rel: "preconnect", href: "https://fonts.googleapis.com"}
        ],
        seo_tags: [
          %{name: "description", content: "Test description"},
          %{name: "keywords", content: "test, layout"}
        ],
        helpers: [
          %{
            name: "format_title",
            args: "title",
            code: "String.upcase(title)"
          }
        ]
      }

      ast = LayoutCompiler.build_module(params)

      assert {:defmodule, _, [_module_name, [do: block]]} = ast
      assert block != nil
    end

    test "handles params with string keys by atomizing them" do
      params = %{
        "title" => "test_layout",
        "layout_module" => TestModule.Layout,
        "template" => ~S(<html><body>Hello</body></html>)
      }

      ast = LayoutCompiler.build_module(params)

      assert {:defmodule, _, _} = ast
    end
  end

  describe "build_layout_information/1" do
    test "builds layout information functions" do
      params = %{
        title: "test_info",
        layout_module: TestModule.InfoLayout,
        id: "layout-id-123",
        priority: 5,
        site: "test-site",
        site_id: "site-123",
        host: "example.com",
        format: :heex,
        path: "/layouts/test",
        permissions: ["view", "edit"],
        extra: %{custom: "data"},
        timestamp: ~U[2024-01-01 00:00:00Z],
        content: "layout content",
        resource_links: [%{rel: "stylesheet", href: "/css/main.css"}],
        seo_tags: [%{name: "description", content: "Test description"}]
      }

      {updated_params, [info_ast]} = LayoutCompiler.build_layout_information(params)

      assert updated_params == params
      assert {:__block__, _, functions} = info_ast

      # Check that it contains the expected function definitions
      assert is_list(functions)
      assert length(functions) > 0
    end

    test "handles missing optional fields with defaults" do
      params = %{
        title: "minimal",
        layout_module: TestModule.Minimal
      }

      {updated_params, [info_ast]} = LayoutCompiler.build_layout_information(params)

      assert updated_params == params
      assert {:__block__, _, _} = info_ast
    end

    # WHETHER DRAWING A PAGE INSIDE THE LAYOUT HAS TO LOAD THE SIGNED-IN USER — see
    # `MishkaCmsCore.Runtime.Compilers.UserClosure`. Anything but an explicit `false` has to be baked
    # as `true`, because the one answer that costs a visitor something is a `false` nobody worked
    # out.
    test "a layout compiled without an answer about the visitor says it reads one" do
      assert layout_information(%{}) =~ "reads_user: true"
    end

    test "only an explicit false about the visitor is carried through" do
      assert layout_information(%{reads_user: false}) =~ "reads_user: false"
      assert layout_information(%{reads_user: true}) =~ "reads_user: true"
    end
  end

  describe "build_render_functions/1" do
    test "builds render functions with template" do
      params = %{
        title: "render_test",
        template: ~S"""
        <html>
          <head><title><%= @title %></title></head>
          <body><%= @inner_content %></body>
        </html>
        """,
        resource_links: [],
        seo_tags: []
      }

      {updated_params, functions_ast} = LayoutCompiler.build_render_functions({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1

      # Check the function AST structure
      [{:__block__, _, defs}] = functions_ast
      # __component_references__/0 + render/1 + render/2
      assert length(defs) == 3
    end

    test "builds render functions with SEO tags and resources" do
      params = %{
        title: "seo_layout",
        template: ~S"""
        <html>
          <head>
            <%= for meta <- @seo.meta_tags do %>
              <meta name={meta.name} content={meta.content}>
            <% end %>
            <%= for link <- @resource_links do %>
              <link rel={link.rel} href={link.href}>
            <% end %>
          </head>
          <body><%= @inner_content %></body>
        </html>
        """,
        resource_links: [
          %{rel: "stylesheet", href: "/app.css"},
          %{rel: "preconnect", href: "https://fonts.com"}
        ],
        seo_tags: [
          %{name: "description", content: "Page description"},
          %{property: "og:title", content: "Social Title"}
        ]
      }

      {updated_params, functions_ast} = LayoutCompiler.build_render_functions({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end

    test "handles empty template" do
      params = %{
        title: "empty",
        template: ""
      }

      {updated_params, functions_ast} = LayoutCompiler.build_render_functions({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end

    test "merges layout data with assigns" do
      params = %{
        title: "merge_test",
        template: ~S(<div><%= @title %> - <%= @custom_value %></div>),
        path: "/test",
        content: "test content"
      }

      {updated_params, functions_ast} = LayoutCompiler.build_render_functions({params, []})

      assert updated_params == params
      # The function should include layout data merging
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

      {updated_params, functions_ast} = LayoutCompiler.build_helpers({params, []})

      assert updated_params == params
      assert length(functions_ast) == 2
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

      {updated_params, functions_ast} = LayoutCompiler.build_helpers({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end

    test "handles empty helpers list" do
      params = %{}

      {updated_params, functions_ast} = LayoutCompiler.build_helpers({params, []})

      assert updated_params == params
      assert functions_ast == []
    end
  end

  describe "build_helpers/1 argument lists" do
    # COMPILED AND CALLED, the way a page's helpers are (`LiveViewCompiler.helper_args/1`).
    test "a helper takes the arguments its args name: none, one or two" do
      params = %{
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
    {_params, helpers} = LayoutCompiler.build_helpers({params, []})
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

  describe "create_module_ast/1" do
    test "creates complete module AST" do
      params = %{
        layout_module: TestModule.FinalLayout
      }

      functions_ast = [
        quote do
          def test_function, do: "test"
        end
      ]

      module_ast = LayoutCompiler.create_module_ast({params, functions_ast})

      assert {:defmodule, _, [module_alias, [do: {:__block__, _, body}]]} = module_ast
      assert module_alias == TestModule.FinalLayout

      # The base is whatever `:web_module` names — the CMS points it at `MishkaCmsWeb`, and with
      # nothing configured it falls back to the library's own.
      web_module =
        Application.get_env(
          :mishka_cms_core,
          :web_module,
          MishkaCmsCore.Runtime.CompiledPageBase
        )

      assert Enum.any?(body, &match?({:use, _, [^web_module, :live_view]}, &1))

      # THE LIST COMES FROM `LiveViewHelpers.imports/1`, which every compiler asks — so it is read
      # from there rather than written out, and `t/1` is asserted by name because it is the reason
      # the list is no longer just `component`.
      imports = MishkaCmsCore.Runtime.LiveViewHelpers.imports(nil)
      assert {:t, 1} in imports

      assert Enum.any?(
               body,
               &match?(
                 {:import, _,
                  [
                    {:__aliases__, _, [:MishkaCmsCore, :Runtime, :LiveViewHelpers]},
                    [only: ^imports]
                  ]},
                 &1
               )
             )
    end
  end

  describe "make_env/0" do
    test "creates environment with proper imports" do
      env = LayoutCompiler.make_env()

      assert %Macro.Env{} = env
      # The function should create an environment
      assert is_list(env.functions)
    end
  end

  describe "integration tests" do
    test "compiles and executes a simple layout" do
      params = %{
        title: "simple_layout",
        layout_module: TestIntegration.SimpleLayout,
        template: ~S"""
        <!DOCTYPE html>
        <html>
          <head><title><%= @title %></title></head>
          <body>
            <main><%= @inner_content %></main>
          </body>
        </html>
        """,
        path: "/layouts/simple",
        site: "main"
      }

      ast = LayoutCompiler.build_module(params)

      # Verify the AST structure
      assert {:defmodule, _, [module_name, _]} = ast
      assert module_name == TestIntegration.SimpleLayout

      # Use ast_to_format_string! for better inspection
      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      assert formatted =~ "__layout_information__"
      assert formatted =~ "simple_layout"
      assert formatted =~ "render"
      assert formatted =~ "inner_content"
    end

    test "compiles layout with helpers and resources" do
      params = %{
        title: "complex_layout",
        layout_module: TestIntegration.ComplexLayout,
        template: ~S'''
        <!DOCTYPE html>
        <html>
          <head>
            <title><%= format_title(@title) %></title>
            <%= for link <- @resource_links do %>
              <link rel={link.rel} href={link.href} type={link[:type]}>
            <% end %>
            <%= for meta <- @seo.meta_tags do %>
              <meta name={meta.name} content={meta.content}>
            <% end %>
          </head>
          <body>
            <header><%= render_header(@user) %></header>
            <main class="container">
              <%= @inner_content %>
            </main>
            <footer>
              <%= @copyright_text %>
            </footer>
          </body>
        </html>
        ''',
        resource_links: [
          %{rel: "stylesheet", href: "/assets/app.css", type: "text/css"},
          %{rel: "preconnect", href: "https://fonts.googleapis.com"}
        ],
        seo_tags: [
          %{name: "description", content: "Site description"},
          %{name: "keywords", content: "elixir, phoenix"},
          %{property: "og:title", content: "My Site"}
        ],
        helpers: [
          %{
            name: "format_title",
            args: "title",
            code: "String.upcase(title)"
          },
          %{
            name: "render_header",
            args: "user",
            code: """
            if user do
              "Welcome, \#{user.name}!"
            else
              "Welcome, Guest!"
            end
            """
          }
        ]
      }

      ast = LayoutCompiler.build_module(params)

      # This should compile without errors
      assert {:defmodule, _, _} = ast

      # Use formatted string for better inspection
      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "format_title"
      assert formatted =~ "render_header"
      assert formatted =~ "resource_links"
      assert formatted =~ "seo"
      assert formatted =~ "meta_tags"
    end

    test "handles layout with complex HEEx template" do
      params = %{
        title: "complex_template",
        layout_module: TestIntegration.ComplexTemplateLayout,
        template: ~S'''
        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title><%= @title %> | <%= @site_name %></title>

            <%= for style <- @styles || [] do %>
              <style><%= style %></style>
            <% end %>
          </head>
          <body class={["layout", @theme || "light"]}>
            <nav :if={@show_nav}>
              <%= for item <- @nav_items || [] do %>
                <a href={item.path} class={if item.active, do: "active", else: ""}>
                  <%= item.label %>
                </a>
              <% end %>
            </nav>

            <aside :if={@show_sidebar} class="sidebar">
              <%= @sidebar_content %>
            </aside>

            <main role="main">
              <div :if={@flash_message} class="flash">
                <%= @flash_message %>
              </div>
              <%= @inner_content %>
            </main>

            <footer>
              <p>&copy; <%= DateTime.utc_now.year %> <%= @site_name %></p>
            </footer>

            <%= for script <- @scripts || [] do %>
              <script src={script}></script>
            <% end %>
          </body>
        </html>
        ''',
        site: "test_site",
        site_id: "site-123",
        permissions: ["layout:view"]
      }

      ast = LayoutCompiler.build_module(params)

      # Should compile complex template without errors
      assert {:defmodule, _, _} = ast

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      # The template is compiled, check for key elements
      assert formatted =~ "nav_items"
      assert formatted =~ "show_sidebar"
      assert formatted =~ "flash_message"
      assert formatted =~ "site_name"
    end

    test "handles layout with metadata and permissions" do
      params = %{
        title: "secure_layout",
        layout_module: TestIntegration.SecureLayout,
        template: ~S"""
        <html>
          <body>
            <div class="secure-content">
              <%= @inner_content %>
            </div>
          </body>
        </html>
        """,
        id: "layout-456",
        site: "admin-site",
        site_id: "site-789",
        host: "admin.example.com",
        path: "/layouts/admin",
        priority: 10,
        permissions: [
          "admin:dashboard:runtime:page",
          "admin:dashboard:runtime:layout",
          "layout:manage"
        ],
        extra: %{
          category: "admin",
          version: "2.0.0",
          features: ["dashboard", "reports"]
        },
        timestamp: ~U[2024-01-15 10:00:00Z]
      }

      ast = LayoutCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check metadata is included
      assert formatted =~ "layout-456"
      assert formatted =~ "admin-site"
      assert formatted =~ "admin:dashboard:runtime:page"
      assert formatted =~ "category"
      assert formatted =~ "version"
      assert formatted =~ "features"
    end

    test "handles malformed input gracefully" do
      # Minimal params with title and template
      params = %{
        title: "error_layout",
        layout_module: TestIntegration.ErrorLayout,
        # Provide empty template to avoid nil error
        template: ""
      }

      # Should still generate AST, even if incomplete
      ast = LayoutCompiler.build_module(params)
      assert {:defmodule, _, _} = ast
    end

    test "compiles layout with multiple helper types" do
      params = %{
        title: "helpers_layout",
        layout_module: TestIntegration.HelpersLayout,
        template: ~S'''
        <html>
          <head>
            <title><%= page_title(@title, @site_name) %></title>
          </head>
          <body>
            <nav>
              <%= render_breadcrumbs(@breadcrumbs) %>
            </nav>
            <main>
              <time><%= format_datetime(@published_at) %></time>
              <div><%= @inner_content %></div>
            </main>
            <footer>
              <%= copyright_notice(@year, @company) %>
            </footer>
          </body>
        </html>
        ''',
        helpers: [
          %{
            name: "page_title",
            args: "{title, site_name}",
            code: """
            if title && title != "" do
              "\#{title} | \#{site_name}"
            else
              site_name
            end
            """
          },
          %{
            name: "render_breadcrumbs",
            args: "{crumbs}",
            code: """
            (crumbs || [])
            |> Enum.map(fn crumb ->
              "<a href='\#{crumb.url}'>\#{crumb.title}</a>"
            end)
            |> Enum.join(" > ")
            """
          },
          %{
            name: "format_datetime",
            args: "{datetime}",
            code: """
            case datetime do
              %DateTime{} = dt -> Calendar.strftime(dt, "%B %d, %Y at %H:%M")
              _ -> "Unknown date"
            end
            """
          },
          %{
            name: "copyright_notice",
            args: "{year, company}",
            code: ~S("&copy; #{year} #{company}. All rights reserved.")
          }
        ]
      }

      ast = LayoutCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check all helpers are defined
      assert formatted =~ "page_title"
      assert formatted =~ "render_breadcrumbs"
      assert formatted =~ "format_datetime"
      assert formatted =~ "copyright_notice"
    end

    test "compiles layout with SEO optimization features" do
      params = %{
        title: "seo_optimized",
        layout_module: TestIntegration.SeoLayout,
        template: ~S'''
        <!DOCTYPE html>
        <html lang={@lang || "en"}>
          <head>
            <meta charset="UTF-8">
            <title><%= @page_title %></title>

            <%= for meta <- @seo.meta_tags do %>
              <%= if meta[:name] do %>
                <meta name={meta.name} content={meta.content}>
              <% else %>
                <meta property={meta.property} content={meta.content}>
              <% end %>
            <% end %>

            <link rel="canonical" href={@canonical_url}>

            <%= for link <- @resource_links do %>
              <link rel={link.rel} href={link.href} type={link[:type]}>
            <% end %>

            <script type="application/ld+json">
              <%= @structured_data %>
            </script>
          </head>
          <body>
            <%= @inner_content %>
          </body>
        </html>
        ''',
        seo_tags: [
          %{name: "description", content: "Comprehensive SEO optimized layout"},
          %{name: "keywords", content: "seo, layout, phoenix, elixir"},
          %{name: "author", content: "Test Author"},
          %{name: "robots", content: "index, follow"},
          %{property: "og:title", content: "SEO Optimized Layout"},
          %{property: "og:description", content: "Testing SEO features"},
          %{property: "og:image", content: "https://example.com/image.jpg"},
          %{property: "og:type", content: "website"},
          %{name: "twitter:card", content: "summary_large_image"},
          %{name: "twitter:site", content: "@example"}
        ],
        resource_links: [
          %{rel: "stylesheet", href: "/css/main.css", type: "text/css"},
          %{rel: "preconnect", href: "https://fonts.gstatic.com"},
          %{rel: "dns-prefetch", href: "//cdn.example.com"},
          %{rel: "alternate", href: "/feed.xml", type: "application/rss+xml"}
        ]
      }

      ast = LayoutCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check SEO elements
      assert formatted =~ "meta_tags"
      assert formatted =~ "canonical_url"
      assert formatted =~ "structured_data"
      assert formatted =~ "og:title"
      assert formatted =~ "twitter:card"
    end

    test "compiles responsive layout with conditional rendering" do
      params = %{
        title: "responsive_layout",
        layout_module: TestIntegration.ResponsiveLayout,
        template: ~S'''
        <!DOCTYPE html>
        <html>
          <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title><%= @title %></title>
          </head>
          <body>
            <header :if={@show_header}>
              <div class="mobile-menu" :if={@is_mobile}>
                <button>Menu</button>
              </div>
              <nav class="desktop-nav" :if={!@is_mobile}>
                <%= for link <- @nav_links do %>
                  <a href={link.url}><%= link.text %></a>
                <% end %>
              </nav>
            </header>

            <div class={if @is_mobile, do: "mobile-container", else: "desktop-container"}>
              <%= @inner_content %>
            </div>

            <aside :if={@show_sidebar && !@is_mobile}>
              <%= @sidebar_content %>
            </aside>

            <footer>
              <div :if={@show_social_links}>
                <%= for social <- @social_links || [] do %>
                  <a href={social.url} target="_blank"><%= social.name %></a>
                <% end %>
              </div>
            </footer>
          </body>
        </html>
        ''',
        site: "responsive_site",
        extra: %{
          breakpoint: "768px",
          mobile_first: true
        }
      }

      ast = LayoutCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check responsive elements
      assert formatted =~ "is_mobile"
      assert formatted =~ "mobile-menu"
      assert formatted =~ "desktop-nav"
      assert formatted =~ "show_sidebar"
      assert formatted =~ "social_links"
    end

    test "handles layout with resource management" do
      params = %{
        title: "resource_layout",
        layout_module: TestIntegration.ResourceLayout,
        template: ~S'''
        <!DOCTYPE html>
        <html>
          <head>
            <%= for css <- @css_files || [] do %>
              <link rel="stylesheet" href={css.href} media={css[:media] || "all"}>
            <% end %>

            <%= for link <- @resource_links do %>
              <link
                rel={link.rel}
                href={link.href}
                type={link[:type]}
                sizes={link[:sizes]}
                integrity={link[:integrity]}
                crossorigin={link[:crossorigin]}
              >
            <% end %>

            <%= for js <- @js_preload || [] do %>
              <link rel="preload" as="script" href={js}>
            <% end %>
          </head>
          <body>
            <%= @inner_content %>

            <%= for js <- @js_files || [] do %>
              <script
                src={js.src}
                async={js[:async]}
                defer={js[:defer]}
                type={if js[:module], do: "module"}
              ></script>
            <% end %>
          </body>
        </html>
        ''',
        resource_links: [
          %{rel: "icon", href: "/favicon.ico", sizes: "32x32"},
          %{rel: "apple-touch-icon", href: "/apple-icon.png", sizes: "180x180"},
          %{rel: "manifest", href: "/site.webmanifest"},
          %{rel: "preconnect", href: "https://cdn.example.com", crossorigin: "anonymous"}
        ]
      }

      ast = LayoutCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check resource management
      assert formatted =~ "css_files"
      assert formatted =~ "js_files"
      assert formatted =~ "js_preload"
      assert formatted =~ "integrity"
      assert formatted =~ "crossorigin"
    end
  end

  defp layout_information(params) do
    {_params, [info_ast]} =
      %{title: "reads_user", layout_module: TestModule.ReadsUser}
      |> Map.merge(params)
      |> LayoutCompiler.build_layout_information()

    info_ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
  end
end
