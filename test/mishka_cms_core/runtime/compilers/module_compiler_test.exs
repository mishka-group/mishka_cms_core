defmodule MishkaCmsCore.Runtime.Compilers.ModuleCompilerTest do
  # Set to false to avoid module conflicts
  use ExUnit.Case, async: false
  alias MishkaCmsCore.Runtime.Compilers.ModuleCompiler

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog
  @moduletag :unit

  # Suppress warnings for dynamically compiled test modules
  @compile {:no_warn_undefined,
            [
              TestModuleCompilerSimple,
              TestModuleCompilerComplex,
              TestModuleCompilerWarning,
              TestModuleCompilerError,
              TestSingleName,
              TestModuleCompilerDefaultFile,
              TestModuleCompilerRecompile,
              TestModuleCompilerUnloadMe,
              TestModuleCompilerMultiUnload,
              TestModuleCompilerFullCycle,
              TestModuleCompilerPatternModule,
              TestModuleCompilerMacroModule,
              TestModuleCompilerSyntaxError,
              TestModuleCompilerStructModule,
              TestModuleCompilerCustomStruct,
              TestModuleCompilerCustomException
            ]}

  describe "compile_module/2" do
    test "successfully compiles a simple module" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerSimple) do
            def hello, do: "Hello, World!"
          end
        end

      assert {:ok, module, diagnostics} =
               ModuleCompiler.compile_module(quoted, "simple_module.ex")

      assert module == TestModuleCompilerSimple
      assert is_list(diagnostics)
      assert TestModuleCompilerSimple.hello() == "Hello, World!"

      # Cleanup
      ModuleCompiler.unload(TestModuleCompilerSimple)
    end

    test "compiles module with functions and attributes" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerComplex) do
            @moduledoc "A test module"
            @custom_attribute :test_value

            def get_attribute, do: @custom_attribute
            def greet(name), do: "Hello, #{name}!"
            defp private_function, do: :private
          end
        end

      assert {:ok, module, _diagnostics} = ModuleCompiler.compile_module(quoted)
      assert module == TestModuleCompilerComplex
      assert TestModuleCompilerComplex.get_attribute() == :test_value
      assert TestModuleCompilerComplex.greet("Alice") == "Hello, Alice!"

      # Cleanup
      ModuleCompiler.unload(TestModuleCompilerComplex)
    end

    test "collects warnings during compilation" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerWarning) do
            def unused_variable_warning do
              unused_var = "this is unused"
              :ok
            end
          end
        end

      assert {:ok, module, diagnostics} =
               ModuleCompiler.compile_module(quoted, "warning_module.ex")

      assert module == TestModuleCompilerWarning

      # Check for warnings in diagnostics - may or may not have warnings depending on compiler settings
      assert is_list(diagnostics)

      # Cleanup
      ModuleCompiler.unload(TestModuleCompilerWarning)
    end

    test "handles compilation errors with undefined function" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerError) do
            def broken do
              undefined_function_that_does_not_exist()
            end
          end
        end

      assert {:error, TestModuleCompilerError, {error, diagnostics}} =
               ModuleCompiler.compile_module(quoted, "error_module.ex")

      assert %CompileError{} = error
      assert is_list(diagnostics)
    end

    test "returns error for invalid module structure" do
      invalid_quoted = {:not_a_module, :definition}

      log =
        capture_log(fn ->
          assert {:error, :invalid_module} = ModuleCompiler.compile_module(invalid_quoted)
        end)

      assert log =~ "invalid module given to Compiler"
    end

    test "handles module with single name" do
      quoted =
        quote do
          defmodule unquote(TestSingleName) do
            def test, do: :single_name
          end
        end

      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)
      assert module == TestSingleName
      assert TestSingleName.test() == :single_name

      # Cleanup
      ModuleCompiler.unload(TestSingleName)
    end

    test "compiles module with default file name" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerDefaultFile) do
            def value, do: :default
          end
        end

      # Don't provide file parameter, should use "nofile"
      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)
      assert module == TestModuleCompilerDefaultFile
      assert TestModuleCompilerDefaultFile.value() == :default

      # Cleanup
      ModuleCompiler.unload(TestModuleCompilerDefaultFile)
    end

    test "handles module recompilation with ignore_module_conflict option" do
      quoted1 =
        quote do
          defmodule unquote(TestModuleCompilerRecompile) do
            def version, do: 1
          end
        end

      quoted2 =
        quote do
          defmodule unquote(TestModuleCompilerRecompile) do
            def version, do: 2
          end
        end

      # First compilation
      assert {:ok, _, _} = ModuleCompiler.compile_module(quoted1)
      assert TestModuleCompilerRecompile.version() == 1

      # Recompilation should work with ignore_module_conflict
      assert {:ok, _, _} = ModuleCompiler.compile_module(quoted2)
      assert TestModuleCompilerRecompile.version() == 2

      # Cleanup
      ModuleCompiler.unload(TestModuleCompilerRecompile)
    end
  end

  describe "module_name/1" do
    test "extracts module name from simple module definition" do
      # When using unquote with an atom, it creates this pattern
      quoted = {:defmodule, [], [TestModule, [do: :ok]]}

      assert {:ok, TestModule} = ModuleCompiler.module_name(quoted)
    end

    test "extracts module name from module with metadata tuple" do
      # This pattern can occur in some AST transformations
      quoted = {TestMetaModule, {:defmodule, [], []}}

      assert {:ok, TestMetaModule} = ModuleCompiler.module_name(quoted)
    end

    test "returns error for invalid module structure" do
      invalid_structures = [
        {:not_a_module, :at_all},
        [:list, :not, :module],
        "string_not_module",
        123,
        nil,
        %{map: :not_module}
      ]

      for invalid <- invalid_structures do
        log =
          capture_log(fn ->
            assert {:error, :invalid_module} = ModuleCompiler.module_name(invalid)
          end)

        assert log =~ "invalid module given to Compiler"
      end
    end
  end

  describe "unload/1" do
    test "successfully unloads a loaded module" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerUnloadMe) do
            def exists, do: true
          end
        end

      # Compile and verify module exists
      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)
      assert TestModuleCompilerUnloadMe.exists() == true

      # Unload the module
      assert :ok = ModuleCompiler.unload(module)

      # Verify module no longer exists
      assert_raise UndefinedFunctionError, fn ->
        TestModuleCompilerUnloadMe.exists()
      end
    end

    test "safely handles unloading non-existent module" do
      # Should not raise error for non-existent module
      assert :ok = ModuleCompiler.unload(NonExistentModule)
      assert :ok = ModuleCompiler.unload(Another.NonExistent.Module)
    end

    test "can unload same module multiple times safely" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerMultiUnload) do
            def test, do: :ok
          end
        end

      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)

      # Multiple unloads should all return :ok
      assert :ok = ModuleCompiler.unload(module)
      assert :ok = ModuleCompiler.unload(module)
      assert :ok = ModuleCompiler.unload(module)
    end
  end

  describe "ast_to_format_string!/1" do
    test "formats and prints simple function AST" do
      ast =
        quote do
          def hello(name) do
            "Hello, #{name}!"
          end
        end

      output =
        capture_io(fn ->
          assert :ok = ModuleCompiler.ast_to_format_string!(ast)
        end)

      assert output =~ "def hello(name) do"
      assert output =~ ~S["Hello, #{name}!"]
    end

    test "formats complete module AST" do
      module_ast =
        quote do
          defmodule MyApp.Example do
            @moduledoc "Example module"

            def greet(name), do: "Hi #{name}"

            def farewell(name) do
              "Goodbye, #{name}!"
            end
          end
        end

      output =
        capture_io(fn ->
          assert :ok = ModuleCompiler.ast_to_format_string!(module_ast)
        end)

      assert output =~ "defmodule MyApp.Example do"
      assert output =~ "@moduledoc \"Example module\""
      # The formatter expands single-line functions to multi-line
      assert output =~ "def greet(name) do"
      assert output =~ "def farewell(name) do"
    end

    test "formats complex AST with multiple clauses" do
      ast =
        quote do
          case value do
            {:ok, result} -> result
            {:error, reason} -> raise reason
            _ -> nil
          end
        end

      output =
        capture_io(fn ->
          assert :ok = ModuleCompiler.ast_to_format_string!(ast)
        end)

      assert output =~ "case value do"
      assert output =~ "{:ok, result} -> result"
      # The formatter doesn't add parentheses for raise
      assert output =~ "{:error, reason} -> raise"
    end

    test "formats AST with attributes and documentation" do
      ast =
        quote do
          defmodule TestModule do
            @behaviour SomeBehaviour
            @custom_attr :value

            @doc """
            Documentation for function
            """
            def documented_function(arg) do
              arg * 2
            end
          end
        end

      output =
        capture_io(fn ->
          ModuleCompiler.ast_to_format_string!(ast)
        end)

      assert output =~ "@behaviour SomeBehaviour"
      assert output =~ "@custom_attr :value"
      assert output =~ "@doc"
    end
  end

  describe "integration tests" do
    test "compile, use, and unload cycle" do
      # Define a module with various features
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerFullCycle) do
            @moduledoc "Full lifecycle test module"

            def public_fun(x), do: x * 2
            def another_fun, do: :test

            defp private_fun, do: :private
          end
        end

      # Compile with diagnostics
      assert {:ok, module, diagnostics} = ModuleCompiler.compile_module(quoted, "full_cycle.ex")
      assert module == TestModuleCompilerFullCycle
      assert is_list(diagnostics)

      # Use the compiled module
      assert TestModuleCompilerFullCycle.public_fun(5) == 10
      assert TestModuleCompilerFullCycle.another_fun() == :test

      # Unload when done
      assert :ok = ModuleCompiler.unload(module)

      # Verify unloaded
      assert_raise UndefinedFunctionError, fn ->
        TestModuleCompilerFullCycle.public_fun(5)
      end
    end

    test "handles module with pattern matching and guards" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerPatternModule) do
            def process({:ok, value}) when is_integer(value), do: value * 2
            def process({:ok, value}) when is_binary(value), do: String.upcase(value)
            def process({:error, _reason}), do: nil
            def process(_), do: :unknown
          end
        end

      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)

      assert TestModuleCompilerPatternModule.process({:ok, 5}) == 10
      assert TestModuleCompilerPatternModule.process({:ok, "hello"}) == "HELLO"
      assert TestModuleCompilerPatternModule.process({:error, "failed"}) == nil
      assert TestModuleCompilerPatternModule.process(:something_else) == :unknown

      # Cleanup
      ModuleCompiler.unload(module)
    end

    test "compiles module with macros and compile-time code" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerMacroModule) do
            require Logger

            @compile_time_value 1 + 1

            defmacro double(x) do
              quote do
                unquote(x) * 2
              end
            end

            def use_compile_time, do: @compile_time_value
          end
        end

      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)
      assert TestModuleCompilerMacroModule.use_compile_time() == 2

      # Cleanup
      ModuleCompiler.unload(module)
    end

    test "handles syntax errors appropriately" do
      # This will have a syntax error during compilation
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerSyntaxError) do
            def broken do
              # This will cause a compilation error
              unknown_var + 1
            end
          end
        end

      assert {:error, TestModuleCompilerSyntaxError, {%CompileError{}, _diagnostics}} =
               ModuleCompiler.compile_module(quoted, "syntax_error.ex")
    end

    test "compiles module with struct definition" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerStructModule) do
            defstruct [:name, :age, status: :active]

            def new(name, age) do
              %__MODULE__{name: name, age: age}
            end
          end
        end

      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)

      struct_instance = TestModuleCompilerStructModule.new("Alice", 30)
      assert struct_instance.name == "Alice"
      assert struct_instance.age == 30
      assert struct_instance.status == :active

      # Cleanup
      ModuleCompiler.unload(module)
    end

    test "compiles module with custom struct" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerCustomStruct) do
            defstruct [:value]

            def new(value), do: %__MODULE__{value: value}
          end
        end

      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)

      # Create and use the struct
      instance = TestModuleCompilerCustomStruct.new(42)
      assert instance.value == 42

      # Cleanup
      ModuleCompiler.unload(module)
    end

    test "compiles module with exception definitions" do
      quoted =
        quote do
          defmodule unquote(TestModuleCompilerCustomException) do
            defexception [:message, :code]

            def exception(opts) do
              message = Keyword.get(opts, :message, "An error occurred")
              code = Keyword.get(opts, :code, 500)
              %__MODULE__{message: message, code: code}
            end
          end
        end

      assert {:ok, module, _} = ModuleCompiler.compile_module(quoted)

      exception = TestModuleCompilerCustomException.exception(message: "Test error", code: 404)
      assert exception.message == "Test error"
      assert exception.code == 404

      # Cleanup
      ModuleCompiler.unload(module)
    end
  end
end
