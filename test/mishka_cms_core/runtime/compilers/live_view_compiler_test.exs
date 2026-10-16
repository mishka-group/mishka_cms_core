# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.LiveViewCompilerTest do
  use ExUnit.Case, async: true
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  @moduletag :unit

  describe "build_module/1" do
    test "builds complete module AST with minimal params" do
      params = %{
        title: "test_page",
        page_module: TestModule.Page,
        template: ~S(<div><h1><%= @title %></h1></div>),
        helpers: []
      }

      ast = LiveViewCompiler.build_module(params)

      assert {:defmodule, _, [_module_name, _]} = ast
    end

    test "builds module with all params including events, infos, and helpers" do
      params = %{
        title: "interactive_page",
        page_module: TestModule.InteractivePage,
        template: ~S"""
        <div>
          <h1><%= @title %></h1>
          <button phx-click="increment">Count: <%= @count %></button>
          <div><%= format_text(@message) %></div>
        </div>
        """,
        events: [
          %{
            name: "increment",
            code: "{:noreply, update(socket, :count, &(&1 + 1))}"
          }
        ],
        infos: [
          %{
            name: ":refresh",
            code: "{:noreply, assign(socket, :refreshed, true)}"
          }
        ],
        helpers: [
          %{
            name: "format_text",
            args: "{text}",
            code: "String.upcase(text)"
          }
        ],
        seo_tags: [
          %{name: "description", content: "Test page"},
          %{property: "og:title", content: "Interactive Page"}
        ],
        schema: [
          %{
            "@context" => "https://schema.org",
            "@type" => "WebPage",
            "name" => "Test Page"
          }
        ]
      }

      ast = LiveViewCompiler.build_module(params)

      assert {:defmodule, _, [_module_name, [do: block]]} = ast
      assert block != nil
    end

    test "handles params with string keys by atomizing them" do
      params = %{
        "title" => "test_page",
        "page_module" => TestModule.Page,
        "template" => ~S(<div>Hello</div>),
        "helpers" => []
      }

      ast = LiveViewCompiler.build_module(params)

      assert {:defmodule, _, _} = ast
    end
  end

  describe "build_assigns/1" do
    test "builds page information functions" do
      params = %{
        title: "test_info",
        page_module: TestModule.InfoPage,
        id: "page-id-123",
        priority: 5,
        site: "test-site",
        site_id: "site-123",
        host: "example.com",
        format: :heex,
        path: "/pages/test",
        section: "blog",
        permissions: ["view", "edit"],
        extra: %{custom: "data"},
        timestamp: ~U[2024-01-01 00:00:00Z],
        content: "page content",
        seo_tags: [%{name: "description", content: "Test description"}],
        schema: [%{"@type" => "Article"}],
        layout: "main"
      }

      {updated_params, [info_ast]} = LiveViewCompiler.build_assigns(params)

      assert updated_params == params
      assert {:__block__, _, functions} = info_ast

      # Check that it contains the expected function definitions
      assert is_list(functions)
      assert length(functions) > 0
    end

    test "keeps the page's description beside its SEO tags and schema" do
      module = Module.concat(__MODULE__, "Described#{System.unique_integer([:positive])}")
      tags = [%{tag: "meta", attrs: %{"property" => "og:title"}, content: "Studio"}]

      {_params, [info_ast]} =
        LiveViewCompiler.build_assigns(%{
          title: "described",
          page_module: module,
          description: "Shown by search engines and link previews.",
          seo_tags: tags,
          schema: [%{"@type" => "WebPage"}]
        })

      Code.compile_quoted(
        quote do
          defmodule unquote(module) do
            unquote(info_ast)
          end
        end
      )

      assert module.__page_information__([:page, :seo]) == %{
               description: "Shown by search engines and link previews.",
               meta_tags: tags,
               schema: [%{"@type" => "WebPage"}]
             }

      assert module.__page_information__("page.seo.description") ==
               "Shown by search engines and link previews."
    end

    test "handles missing optional fields with defaults" do
      params = %{
        title: "minimal",
        page_module: TestModule.Minimal
      }

      {updated_params, [info_ast]} = LiveViewCompiler.build_assigns(params)

      assert updated_params == params
      assert {:__block__, _, _} = info_ast
    end

    # WHETHER SERVING THE PAGE HAS TO LOAD THE SIGNED-IN USER — see
    # `MishkaCmsCore.Runtime.Compilers.UserClosure`. Anything but an explicit `false` has to be
    # baked as `true`, because the one answer that costs a visitor something is a `false` nobody
    # worked out.
    test "a page compiled without an answer about the visitor says it reads one" do
      assert page_information(%{}) =~ "reads_user: true"
    end

    test "only an explicit false about the visitor is carried through" do
      assert page_information(%{reads_user: false}) =~ "reads_user: false"
      assert page_information(%{reads_user: true}) =~ "reads_user: true"
    end
  end

  describe "build_event_handlers/1" do
    test "builds event handler functions" do
      params = %{
        events: [
          %{
            name: "click_button",
            code: "{:noreply, assign(socket, :clicked, true)}"
          },
          %{
            name: "submit_form",
            code: """
            case validate_form(params) do
              {:ok, data} -> {:noreply, assign(socket, :form_data, data)}
              {:error, errors} -> {:noreply, assign(socket, :errors, errors)}
            end
            """
          }
        ]
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_event_handlers({params, []})

      assert updated_params == params
      # 2 event handlers + 1 catch-all
      assert length(functions_ast) == 3

      # Check for catch-all handler
      assert Enum.any?(functions_ast, fn
               {:def, _, [{:handle_event, _, [_, _, {:socket, _, _}]} | _]} -> true
               _ -> false
             end)
    end

    test "adds catch-all event handler when no events defined" do
      params = %{}

      {updated_params, functions_ast} = LiveViewCompiler.build_event_handlers({params, []})

      assert updated_params == params
      # Only catch-all handler
      assert length(functions_ast) == 1
    end

    test "handles complex event handler code" do
      params = %{
        events: [
          %{
            name: "complex_action",
            code: """
            user_id = socket.assigns[:user_id]

            result =
              user_id
              |> fetch_user_data()
              |> process_data()
              |> update_database()

            case result do
              {:ok, data} ->
                {:noreply,
                 socket
                 |> assign(:data, data)
                 |> put_flash(:info, "Success!")}

              {:error, reason} ->
                {:noreply, put_flash(socket, :error, "Failed: \#{reason}")}
            end
            """
          }
        ]
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_event_handlers({params, []})

      assert updated_params == params
      # 1 event handler + 1 catch-all
      assert length(functions_ast) == 2
    end
  end

  # COUNTING THE AST PROVES THE CLAUSE EXISTS, NOT THAT A MESSAGE REACHES IT — and for the whole life
  # of this feature it did not. `info.name` was unquoted as a STRING, so `:tick` compiled to
  # `handle_info(":tick", socket)`, which no message can match; every info handler anyone wrote fell
  # through to the catch-all and did nothing, silently. These compile the generated clauses and send
  # them a real message.
  describe "an info handler actually receives its message" do
    defp compile_infos!(infos) do
      {_params, ast} = LiveViewCompiler.build_info_handlers({%{infos: infos}, []})
      module = Module.concat(__MODULE__, "Infos#{System.unique_integer([:positive])}")

      Module.create(module, {:__block__, [], ast}, Macro.Env.location(__ENV__))
      module
    end

    test "an atom name matches the atom, not the string spelling of it" do
      module = compile_infos!([%{name: ":tick", code: "{:handled, socket}"}])

      assert module.handle_info(:tick, :state) == {:handled, :state}
      assert module.handle_info(":tick", :state) == {:noreply, :state}, "the catch-all takes it"
    end

    # The whole reason to match on a tuple: the body needs what the message carried.
    test "a tuple name binds its variables into the body" do
      module = compile_infos!([%{name: "{:user_updated, user}", code: "{:bound, user, socket}"}])

      assert module.handle_info({:user_updated, 42}, :state) == {:bound, 42, :state}
      assert module.handle_info({:other, 42}, :state) == {:noreply, :state}
    end

    test "several handlers coexist and each takes its own message" do
      module =
        compile_infos!([
          %{name: ":tick", code: "{:ticked, socket}"},
          %{name: "{:done, id}", code: "{:done, id, socket}"}
        ])

      assert module.handle_info(:tick, :state) == {:ticked, :state}
      assert module.handle_info({:done, 7}, :state) == {:done, 7, :state}
      assert module.handle_info(:anything_else, :state) == {:noreply, :state}
    end

    # A BARE NAME MATCHES EVERY MESSAGE. `tick` with the colon left off — the likeliest typo here —
    # parses to a variable, and a variable in the first clause swallows everything the page ever
    # receives, including the messages its other handlers were written for. Skipped, not compiled,
    # and not raised either: a page already carrying such a name still compiles and behaves exactly
    # as it did before this function was fixed.
    test "a bare name is skipped rather than allowed to swallow every message" do
      {module, log} =
        ExUnit.CaptureLog.with_log(fn ->
          compile_infos!([
            %{name: "tick", code: "{:swallowed, socket}"},
            %{name: ":real", code: "{:real, socket}"}
          ])
        end)

      assert log =~ "would match every message"
      assert module.handle_info(:real, :state) == {:real, :state}
      assert module.handle_info(:tick, :state) == {:noreply, :state}
      assert module.handle_info(:anything, :state) == {:noreply, :state}
    end

    test "a blank name contributes no clause" do
      module = compile_infos!([%{name: "   ", code: "{:blank, socket}"}])

      assert module.handle_info(:anything, :state) == {:noreply, :state}
    end
  end

  describe "build_info_handlers/1" do
    test "builds info handler functions" do
      params = %{
        infos: [
          %{
            name: ":tick",
            code: "{:noreply, assign(socket, :time, DateTime.utc_now())}"
          },
          %{
            name: "{:update, data}",
            code: "{:noreply, assign(socket, :data, data)}"
          }
        ]
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_info_handlers({params, []})

      assert updated_params == params
      # 2 info handlers + 1 catch-all
      assert length(functions_ast) == 3
    end

    test "adds catch-all info handler when no infos defined" do
      params = %{}

      {updated_params, functions_ast} = LiveViewCompiler.build_info_handlers({params, []})

      assert updated_params == params
      # Only catch-all handler
      assert length(functions_ast) == 1
    end

    test "handles pattern matching in info handlers" do
      params = %{
        infos: [
          %{
            name: "{:user_update, %{id: user_id, name: name}}",
            code: """
            if socket.assigns[:current_user_id] == user_id do
              {:noreply, assign(socket, :current_user_name, name)}
            else
              {:noreply, socket}
            end
            """
          }
        ]
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_info_handlers({params, []})

      assert updated_params == params
      # 1 info handler + 1 catch-all
      assert length(functions_ast) == 2
    end
  end

  describe "build_renders/1" do
    test "builds render functions with template" do
      params = %{
        title: "render_test",
        template: ~S"""
        <div>
          <h1><%= @title %></h1>
          <p><%= @content %></p>
        </div>
        """,
        template_name: "test",
        site: "main"
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_renders({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1

      # Check the function AST structure
      [{:__block__, _, defs}] = functions_ast
      # render/1 + templates/1
      assert length(defs) == 2
    end

    test "handles empty template" do
      params = %{
        title: "empty",
        template: "",
        template_name: "empty",
        site: "main"
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_renders({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end

    test "compiles complex HEEx template" do
      params = %{
        title: "complex",
        template: ~S"""
        <div class={["page", @theme]}>
          <%= for item <- @items || [] do %>
            <div class="item" id={"item-#{item.id}"}>
              <h3><%= item.title %></h3>
              <button phx-click="delete" phx-value-id={item.id}>
                Delete
              </button>
            </div>
          <% end %>

          <div :if={@show_footer}>
            Footer content
          </div>
        </div>
        """,
        template_name: "complex",
        site: "main"
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_renders({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end
  end

  describe "build_helpers/1" do
    test "builds helper functions" do
      params = %{
        helpers: [
          %{
            name: "format_date",
            args: "{date}",
            code: "Calendar.strftime(date, \"%Y-%m-%d\")"
          },
          %{
            name: "capitalize",
            args: "{text}",
            code: "String.capitalize(text)"
          }
        ]
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_helpers({params, []})

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

      {updated_params, functions_ast} = LiveViewCompiler.build_helpers({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end

    test "handles empty helpers list" do
      params = %{
        helpers: []
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_helpers({params, []})

      assert updated_params == params
      assert functions_ast == []
    end

    # THE ARGUMENT LIST IS A LIST, not a term. Every case below except the single name used to be
    # impossible: `args` was parsed on its own, so `"a, b"` asked Elixir to read a comma-separated
    # pair as one expression and raised `SyntaxError` on the comma — and `"a, b"` is the placeholder
    # the page form suggests. The tuple spelling in the tests above is the workaround it forced.
    defp helper_head(args) do
      {_params, [ast]} =
        LiveViewCompiler.build_helpers(
          {%{helpers: [%{name: "greet", args: args, code: ":ok"}]}, []}
        )

      ast |> Macro.to_string() |> String.split("\n") |> hd()
    end

    test "an empty argument list makes a function of no arguments" do
      assert helper_head("") == "def greet() do"
      assert helper_head("   ") == "def greet() do"
      assert helper_head(nil) == "def greet() do"
    end

    test "one name makes one argument" do
      assert helper_head("name") == "def greet(name) do"
    end

    test "two names make two arguments" do
      assert helper_head("first, second") == "def greet(first, second) do"
    end

    test "the argument list may pattern match and may carry a default" do
      assert helper_head("%{id: id}") == "def greet(%{id: id}) do"
      assert helper_head("a, b \\\\ 1") == "def greet(a, b \\\\ 1) do"
    end

    test "a tuple is still one argument, so helpers written the old way keep working" do
      assert helper_head("{first, second}") == "def greet({first, second}) do"
    end

    test "builds helper with default arguments" do
      params = %{
        helpers: [
          %{
            name: "format_price",
            args: "{price, currency \\\\ \"USD\"}",
            code: ~S("#{currency} #{price}")
          }
        ]
      }

      {updated_params, functions_ast} = LiveViewCompiler.build_helpers({params, []})

      assert updated_params == params
      assert length(functions_ast) == 1
    end
  end

  describe "create_module_ast/1" do
    test "creates complete module AST" do
      params = %{
        page_module: TestModule.FinalPage
      }

      functions_ast = [
        quote do
          def test_function(), do: "test"
        end
      ]

      module_ast = LiveViewCompiler.create_module_ast({params, functions_ast})

      assert {:defmodule, _, [module_alias, [do: {:__block__, _, body}]]} = module_ast
      assert module_alias == TestModule.FinalPage

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
      env = LiveViewCompiler.make_env()

      assert %Macro.Env{} = env
      # The function should create an environment
      assert is_list(env.functions)
    end

    test "creates environment with specific imports" do
      # This would require Phoenix.Component to be available
      # Skip if module not loaded
      if Code.ensure_loaded?(Phoenix.Component) do
        env = LiveViewCompiler.make_env([Phoenix.Component])
        assert %Macro.Env{} = env
        assert length(env.functions) > 0
      end
    end
  end

  describe "render_template/2" do
    test "renders simple template" do
      template = ~S(<div><%= @name %></div>)
      assigns = %{name: "John"}

      result = LiveViewCompiler.render_template(template, assigns)

      assert result == "<div>John</div>"
    end

    test "renders template with conditional" do
      template = ~S"""
      <div>
        <%= if @show do %>
          <p>Visible</p>
        <% else %>
          <p>Hidden</p>
        <% end %>
      </div>
      """

      result1 = LiveViewCompiler.render_template(template, %{show: true})
      assert result1 =~ "Visible"
      refute result1 =~ "Hidden"

      result2 = LiveViewCompiler.render_template(template, %{show: false})
      assert result2 =~ "Hidden"
      refute result2 =~ "Visible"
    end

    test "renders template with list comprehension" do
      template = ~S"""
      <ul>
        <%= for item <- @items do %>
          <li><%= item %></li>
        <% end %>
      </ul>
      """

      result = LiveViewCompiler.render_template(template, %{items: ["a", "b", "c"]})

      assert result =~ "<li>a</li>"
      assert result =~ "<li>b</li>"
      assert result =~ "<li>c</li>"
    end

    test "handles template rendering errors" do
      template = ~S[<div><%= undefined_function() %></div>]

      result = LiveViewCompiler.render_template(template, %{})

      assert {:error, error} = result
      assert error =~ "undefined"
    end
  end

  describe "render_template!/2" do
    test "renders template successfully" do
      template = ~S(<div><%= @text %></div>)

      result = LiveViewCompiler.render_template!(template, %{text: "Success"})

      assert result == "<div>Success</div>"
    end

    test "raises on template error" do
      template = ~S[<div><%= undefined_function() %></div>]

      assert_raise RuntimeError, ~r/Template rendering failed/, fn ->
        LiveViewCompiler.render_template!(template, %{})
      end
    end
  end

  describe "integration tests" do
    test "compiles and executes a simple LiveView page" do
      params = %{
        title: "simple_page",
        page_module: TestIntegration.SimplePage,
        template: ~S"""
        <div class="page">
          <h1><%= @title %></h1>
          <p>Welcome to <%= @site_name %>!</p>
        </div>
        """,
        path: "/pages/simple",
        site: "main",
        helpers: []
      }

      ast = LiveViewCompiler.build_module(params)

      # Verify the AST structure
      assert {:defmodule, _, [module_name, _]} = ast
      assert module_name == TestIntegration.SimplePage

      # Use ast_to_format_string! for better inspection
      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      assert formatted =~ "__page_information__"
      assert formatted =~ "simple_page"
      assert formatted =~ "render"
      assert formatted =~ "templates"
    end

    test "compiles LiveView with event handlers and helpers" do
      params = %{
        title: "interactive_page",
        page_module: TestIntegration.InteractivePage,
        template: ~S'''
        <div class="counter-page">
          <h1><%= format_title(@title) %></h1>

          <div class="counter">
            <button phx-click="decrement">-</button>
            <span class="count"><%= @count %></span>
            <button phx-click="increment">+</button>
          </div>

          <button phx-click="reset">Reset</button>

          <div :if={@message}>
            <p><%= @message %></p>
          </div>
        </div>
        ''',
        events: [
          %{
            name: "increment",
            code: """
            count = (socket.assigns[:count] || 0) + 1
            message = if count >= 10, do: "You reached 10!", else: nil
            {:noreply,
             socket
             |> assign(:count, count)
             |> assign(:message, message)}
            """
          },
          %{
            name: "decrement",
            code: """
            count = max(0, (socket.assigns[:count] || 0) - 1)
            {:noreply, assign(socket, :count, count)}
            """
          },
          %{
            name: "reset",
            code: """
            {:noreply,
             socket
             |> assign(:count, 0)
             |> assign(:message, nil)}
            """
          }
        ],
        helpers: [
          %{
            name: "format_title",
            args: "{title}",
            code: "String.upcase(title)"
          }
        ]
      }

      ast = LiveViewCompiler.build_module(params)

      # This should compile without errors
      assert {:defmodule, _, _} = ast

      # Use formatted string for better inspection
      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
      assert formatted =~ "handle_event"
      assert formatted =~ "increment"
      assert formatted =~ "decrement"
      assert formatted =~ "reset"
      assert formatted =~ "format_title"
    end

    test "compiles LiveView with info handlers and real-time updates" do
      params = %{
        title: "realtime_page",
        page_module: TestIntegration.RealtimePage,
        template: ~S'''
        <div class="realtime">
          <h2>Live Data Dashboard</h2>

          <div class="stats">
            <p>Users Online: <%= @users_online %></p>
            <p>Last Update: <%= @last_update %></p>
          </div>

          <div :if={@notification}>
            <div class="notification">
              <%= @notification %>
            </div>
          </div>

          <button phx-click="refresh">Refresh Data</button>
        </div>
        ''',
        helpers: [],
        events: [
          %{
            name: "refresh",
            code: """
            send(self(), :fetch_data)
            {:noreply, assign(socket, :loading, true)}
            """
          }
        ],
        infos: [
          %{
            name: ":fetch_data",
            code: """
            # Simulate fetching data
            users_online = :rand.uniform(100)

            {:noreply,
             socket
             |> assign(:users_online, users_online)
             |> assign(:last_update, DateTime.utc_now())
             |> assign(:loading, false)}
            """
          },
          %{
            name: "{:broadcast, message}",
            code: """
            {:noreply, assign(socket, :notification, message)}
            """
          },
          %{
            name: ":tick",
            code: """
            # Schedule next tick
            Process.send_after(self(), :tick, 5000)

            # Update data
            {:noreply, assign(socket, :last_update, DateTime.utc_now())}
            """
          }
        ]
      }

      ast = LiveViewCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check info handlers
      assert formatted =~ "handle_info"
      assert formatted =~ ":fetch_data"
      assert formatted =~ "{:broadcast, message}"
      assert formatted =~ ":tick"
    end

    test "handles LiveView with SEO and schema metadata" do
      params = %{
        title: "seo_page",
        page_module: TestIntegration.SeoPage,
        template: ~S"""
        <article>
          <h1><%= @title %></h1>
          <p><%= @description %></p>
        </article>
        """,
        helpers: [],
        id: "page-789",
        site: "blog-site",
        site_id: "site-321",
        host: "blog.example.com",
        path: "/articles/test",
        section: "technology",
        priority: 10,
        permissions: ["article:view", "article:comment"],
        seo_tags: [
          %{name: "description", content: "An informative article about technology"},
          %{name: "keywords", content: "tech, programming, elixir"},
          %{name: "author", content: "Test Author"},
          %{property: "og:title", content: "Technology Article"},
          %{property: "og:description", content: "Learn about the latest in tech"},
          %{property: "og:type", content: "article"},
          %{name: "twitter:card", content: "summary"}
        ],
        schema: [
          %{
            "@context" => "https://schema.org",
            "@type" => "Article",
            "headline" => "Technology Article",
            "author" => %{
              "@type" => "Person",
              "name" => "Test Author"
            },
            "datePublished" => "2024-01-15",
            "description" => "An informative article"
          }
        ],
        extra: %{
          reading_time: "5 min",
          tags: ["elixir", "phoenix", "liveview"]
        }
      }

      ast = LiveViewCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check metadata is included
      assert formatted =~ "page-789"
      assert formatted =~ "blog-site"
      assert formatted =~ "article:view"
      assert formatted =~ "technology"
      assert formatted =~ "@context"
      assert formatted =~ "reading_time"
    end

    test "handles malformed input gracefully" do
      # Minimal params with title and template
      params = %{
        title: "error_page",
        page_module: TestIntegration.ErrorPage,
        # Empty template
        template: "",
        helpers: []
      }

      # Should still generate AST, even if incomplete
      ast = LiveViewCompiler.build_module(params)
      assert {:defmodule, _, _} = ast
    end

    test "compiles LiveView with complex helper functions" do
      params = %{
        title: "helpers_page",
        page_module: TestIntegration.HelpersPage,
        template: ~S'''
        <div class="helpers-demo">
          <h1><%= page_title(@title, @subtitle) %></h1>

          <div class="price-display">
            <%= format_price(@price, @currency) %>
          </div>

          <div class="date-display">
            <%= format_date(@date, @format) %>
          </div>

          <div class="status">
            <%= render_status_badge(@status) %>
          </div>

          <div class="pagination">
            <%= render_pagination(@current_page, @total_pages) %>
          </div>
        </div>
        ''',
        helpers: [
          %{
            name: "page_title",
            args: "{title, subtitle}",
            code: """
            if subtitle && subtitle != "" do
              "\#{title} - \#{subtitle}"
            else
              title
            end
            """
          },
          %{
            name: "format_price",
            args: "{price, currency}",
            code: """
            case currency do
              "USD" -> "$\#{price}"
              "EUR" -> "€\#{price}"
              "GBP" -> "£\#{price}"
              _ -> "\#{price} \#{currency}"
            end
            """
          },
          %{
            name: "format_date",
            args: "{date, format}",
            code: """
            case format do
              :short -> Calendar.strftime(date, "%m/%d/%Y")
              :long -> Calendar.strftime(date, "%B %d, %Y")
              :iso -> Date.to_iso8601(date)
              _ -> Date.to_string(date)
            end
            """
          },
          %{
            name: "render_status_badge",
            args: "{status}",
            code: """
            class = case status do
              "active" -> "badge-green"
              "pending" -> "badge-yellow"
              "inactive" -> "badge-red"
              _ -> "badge-gray"
            end

            ~H\"""
            <span class={"badge " <> class}>
              <%= String.capitalize(status) %>
            </span>
            \"""
            """
          },
          %{
            name: "render_pagination",
            args: "{current, total}",
            code: """
            pages = if total <= 5 do
              1..total
            else
              start_page = max(1, current - 2)
              end_page = min(total, current + 2)
              start_page..end_page
            end

            ~H\"""
            <div class="pagination">
              <%= for page <- pages do %>
                <button phx-click="change_page" phx-value-page={page}
                        class={if page == current, do: "active", else: ""}>
                  <%= page %>
                </button>
              <% end %>
            </div>
            \"""
            """
          }
        ]
      }

      ast = LiveViewCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check all helpers are defined
      assert formatted =~ "page_title"
      assert formatted =~ "format_price"
      assert formatted =~ "format_date"
      assert formatted =~ "render_status_badge"
      assert formatted =~ "render_pagination"
    end

    test "compiles LiveView with form handling" do
      params = %{
        title: "form_page",
        page_module: TestIntegration.FormPage,
        helpers: [],
        template: ~S'''
        <div class="form-page">
          <h2>User Registration</h2>

          <form phx-submit="save_form" phx-change="validate_form">
            <div class="field">
              <label for="name">Name</label>
              <input type="text" name="name" value={@form[:name]} />
              <span :if={@errors[:name]} class="error">
                <%= @errors[:name] %>
              </span>
            </div>

            <div class="field">
              <label for="email">Email</label>
              <input type="email" name="email" value={@form[:email]} />
              <span :if={@errors[:email]} class="error">
                <%= @errors[:email] %>
              </span>
            </div>

            <button type="submit" disabled={!@valid}>
              Submit
            </button>
          </form>

          <div :if={@success} class="success">
            Registration successful!
          </div>
        </div>
        ''',
        events: [
          %{
            name: "validate_form",
            code: """
            errors = %{}

            errors = if params["name"] == "",
              do: Map.put(errors, :name, "Name is required"),
              else: errors

            errors = if !String.contains?(params["email"] || "", "@"),
              do: Map.put(errors, :email, "Invalid email"),
              else: errors

            {:noreply,
             socket
             |> assign(:form, params)
             |> assign(:errors, errors)
             |> assign(:valid, map_size(errors) == 0)}
            """
          },
          %{
            name: "save_form",
            code: """
            if socket.assigns[:valid] do
              # Simulate saving to database
              {:noreply,
               socket
               |> assign(:success, true)
               |> assign(:form, %{})
               |> assign(:errors, %{})}
            else
              {:noreply, socket}
            end
            """
          }
        ]
      }

      ast = LiveViewCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check form handling
      assert formatted =~ "validate_form"
      assert formatted =~ "save_form"
      assert formatted =~ "phx-submit"
      assert formatted =~ "phx-change"
    end

    test "compiles LiveView with conditional rendering and loops" do
      params = %{
        title: "conditional_page",
        page_module: TestIntegration.ConditionalPage,
        helpers: [],
        template: ~S'''
        <div class="conditional-demo">
          <div :if={@user_signed_in}>
            <p>Welcome, <%= @user_name %>!</p>
            <button phx-click="sign_out">Sign Out</button>
          </div>

          <div :if={!@user_signed_in}>
            <p>Please sign in</p>
            <button phx-click="sign_in">Sign In</button>
          </div>

          <div :for={notification <- @notifications} class="notification">
            <span><%= notification.message %></span>
            <button phx-click="dismiss" phx-value-id={notification.id}>
              ×
            </button>
          </div>

          <table :if={@show_table && @data != []}>
            <thead>
              <tr>
                <%= for col <- @columns do %>
                  <th><%= col %></th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <%= for row <- @data do %>
                <tr>
                  <%= for col <- @columns do %>
                    <td><%= Map.get(row, col) %></td>
                  <% end %>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
        ''',
        events: [
          %{
            name: "sign_in",
            code: """
            {:noreply,
             socket
             |> assign(:user_signed_in, true)
             |> assign(:user_name, "Test User")}
            """
          },
          %{
            name: "sign_out",
            code: """
            {:noreply,
             socket
             |> assign(:user_signed_in, false)
             |> assign(:user_name, nil)}
            """
          },
          %{
            name: "dismiss",
            code: """
            id = String.to_integer(params["id"])
            notifications = Enum.reject(socket.assigns.notifications,
                                       &(&1.id == id))
            {:noreply, assign(socket, :notifications, notifications)}
            """
          }
        ]
      }

      ast = LiveViewCompiler.build_module(params)

      formatted = ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()

      # Check conditional rendering elements are present in the compiled code
      assert formatted =~ "user_signed_in"
      assert formatted =~ "notifications"
      assert formatted =~ "sign_in"
      assert formatted =~ "sign_out"
      assert formatted =~ "dismiss"
    end
  end

  defp page_information(params) do
    {_params, [info_ast]} =
      %{title: "reads_user", page_module: TestModule.ReadsUser}
      |> Map.merge(params)
      |> LiveViewCompiler.build_assigns()

    info_ast |> Macro.to_string() |> Code.format_string!() |> Enum.join()
  end
end
