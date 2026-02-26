defmodule MishkaCmsCore.Runtime.Compilers.ComponentImportMacroCompilerTest do
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.Compilers.ComponentImportMacroCompiler
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler
  @moduletag :unit

  # Define test modules for imports
  defmodule TestComponents.Button do
    def button(text), do: "<button>#{text}</button>"
    def link_button(text, href), do: "<a href='#{href}'><button>#{text}</button></a>"
  end

  defmodule TestComponents.Alert do
    def alert(message), do: "<div class='alert'>#{message}</div>"
    def flash(type, message), do: "<div class='flash-#{type}'>#{message}</div>"
  end

  defmodule TestComponents.Form do
    def text_input(name), do: "<input type='text' name='#{name}' />"
    def submit_button(text), do: "<button type='submit'>#{text}</button>"
    def form(action), do: "<form action='#{action}'></form>"
  end

  # Suppress warnings for dynamically compiled test modules
  @compile {:no_warn_undefined,
            [
              TestRuntimeImports,
              TestSelectiveImports,
              TestEmptyImports,
              TestMultipleImports,
              TestRuntimeComponentImports,
              TestUserModule,
              TestSelectiveComponentImports,
              TestSelectiveUserModule
            ]}

  describe "build_module/1" do
    test "builds module with single import" do
      params = %{
        module_name: TestRuntimeImports,
        imports: [
          {TestComponents.Button, [button: 1]}
        ]
      }

      ast = ComponentImportMacroCompiler.build_module(params)

      assert {:defmodule, _, [TestRuntimeImports, _]} = ast

      # Compile the module
      assert {:ok, module, _} = ModuleCompiler.compile_module(ast)
      assert module == TestRuntimeImports

      # Clean up
      ModuleCompiler.unload(TestRuntimeImports)
    end

    test "builds module with multiple imports from different modules" do
      params = %{
        module_name: TestMultipleImports,
        imports: [
          {TestComponents.Button, [button: 1, link_button: 2]},
          {TestComponents.Alert, [alert: 1, flash: 2]},
          {TestComponents.Form, [text_input: 1]}
        ]
      }

      ast = ComponentImportMacroCompiler.build_module(params)

      assert {:defmodule, _, [TestMultipleImports, _]} = ast

      # Compile the module
      assert {:ok, module, _} = ModuleCompiler.compile_module(ast)
      assert module == TestMultipleImports

      # Clean up
      ModuleCompiler.unload(TestMultipleImports)
    end

    test "builds module with selective imports" do
      params = %{
        module_name: TestSelectiveImports,
        imports: [
          {TestComponents.Form, [form: 1, submit_button: 1]}
          # Note: text_input is not imported
        ]
      }

      ast = ComponentImportMacroCompiler.build_module(params)

      # Compile the module
      assert {:ok, module, _} = ModuleCompiler.compile_module(ast)
      assert module == TestSelectiveImports

      # Clean up
      ModuleCompiler.unload(TestSelectiveImports)
    end

    test "builds module with empty imports" do
      params = %{
        module_name: TestEmptyImports,
        imports: []
      }

      ast = ComponentImportMacroCompiler.build_module(params)

      assert {:defmodule, _, [TestEmptyImports, _]} = ast

      # Should compile successfully even with no imports
      assert {:ok, module, _} = ModuleCompiler.compile_module(ast)
      assert module == TestEmptyImports

      # Clean up
      ModuleCompiler.unload(TestEmptyImports)
    end

    test "handles string keys by atomizing them" do
      params = %{
        "module_name" => TestRuntimeImports,
        "imports" => [
          {TestComponents.Alert, [alert: 1]}
        ]
      }

      ast = ComponentImportMacroCompiler.build_module(params)

      assert {:defmodule, _, [TestRuntimeImports, _]} = ast

      # Clean up after compilation
      {:ok, module, _} = ModuleCompiler.compile_module(ast)
      ModuleCompiler.unload(module)
    end
  end

  describe "integration test" do
    test "generated module can be used to import functions" do
      # Step 1: Create the import macro module
      params = %{
        module_name: TestRuntimeComponentImports,
        imports: [
          {TestComponents.Button, [button: 1]},
          {TestComponents.Alert, [flash: 2]}
        ]
      }

      ast = ComponentImportMacroCompiler.build_module(params)
      assert {:ok, _, _} = ModuleCompiler.compile_module(ast)

      # Step 2: Create a module that uses the generated import module
      user_module_ast =
        quote do
          defmodule TestUserModule do
            use TestRuntimeComponentImports

            def render_button do
              button("Click me")
            end

            def render_flash do
              flash(:info, "Success!")
            end
          end
        end

      assert {:ok, _, _} = ModuleCompiler.compile_module(user_module_ast)

      # Step 3: Verify the imported functions work
      assert TestUserModule.render_button() == "<button>Click me</button>"
      assert TestUserModule.render_flash() == "<div class='flash-info'>Success!</div>"

      # Clean up
      ModuleCompiler.unload(TestUserModule)
      ModuleCompiler.unload(TestRuntimeComponentImports)
    end

    test "selective imports only import specified functions" do
      # Create import module with only specific functions
      params = %{
        module_name: TestSelectiveComponentImports,
        imports: [
          {TestComponents.Form, [text_input: 1]}
          # submit_button and form are NOT imported
        ]
      }

      ast = ComponentImportMacroCompiler.build_module(params)
      assert {:ok, _, _} = ModuleCompiler.compile_module(ast)

      # Create a module that tries to use the imports
      user_module_ast =
        quote do
          defmodule TestSelectiveUserModule do
            use TestSelectiveComponentImports

            def render_input do
              text_input("username")
            end

            # This would fail if we tried to call submit_button
            # since it's not imported
          end
        end

      assert {:ok, _, _} = ModuleCompiler.compile_module(user_module_ast)

      # Verify only imported function works
      assert TestSelectiveUserModule.render_input() == "<input type='text' name='username' />"

      # Clean up
      ModuleCompiler.unload(TestSelectiveUserModule)
      ModuleCompiler.unload(TestSelectiveComponentImports)
    end
  end
end
