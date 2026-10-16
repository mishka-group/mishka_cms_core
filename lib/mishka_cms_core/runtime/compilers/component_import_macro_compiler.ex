# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.ComponentImportMacroCompiler do
  @moduledoc """
  Runtime compiler for generating component import macro modules.

  This module provides functionality to dynamically create modules with `__using__` macros
  that import specific functions from various component modules. This enables runtime
  composition of component libraries with selective function imports.

  ## Purpose

  The primary use case is to create dynamic import modules at runtime that can be used
  with `use` statements in other modules to import specific functions from component
  libraries. This is particularly useful in CMS systems where component availability
  needs to be configured dynamically.

  ## Generated Module Structure

  The generated module contains:
  - A `__using__/1` macro that handles selective imports
  - Import statements for each specified module and function list
  - Proper macro expansion for compile-time import resolution

  ## Usage Pattern

      # Create the import module
      params = %{
        module_name: MyApp.RuntimeComponents,
        imports: [
          {MyApp.Components.Alert, [flash: 1, alert: 1]},
          {MyApp.Components.Button, [button: 1]}
        ]
      }

      ast = ComponentImportMacroCompiler.build_module(params)
      MishkaCmsCore.Runtime.Compilers.ModuleCompiler.compile_module(ast)

      # Use the generated module
      defmodule MyView do
        use MyApp.RuntimeComponents

        # Now has access to flash/1, alert/1, button/1
      end

  ## Benefits

  - **Selective imports**: Only import specific functions, not entire modules
  - **Runtime configuration**: Component availability can be configured at runtime
  - **Namespace management**: Avoid function name conflicts
  - **Performance**: Only imported functions are available, reducing compile overhead

  ## Parameters

  - `params` - Map containing module configuration with keys:
    - `:module_name` - Target module name (required)
    - `:imports` - List of `{module, functions}` tuples (required)

  ## Import Format

  Each import tuple consists of:
  - `module` - The module to import from (e.g., `MyApp.Components.Button`)
  - `functions` - List of `{function_name, arity}` tuples or keyword list format
  """

  @doc """
  Builds a module with imported functions based on the provided parameters.
  """
  def build_module(params) do
    MishkaCmsCore.Runtime.Helpers.atomize_keys(params)
    |> build_imports()
    |> create_module_ast()
  end

  # Build import statements from configuration.
  #
  # Processes the imports configuration and generates AST for import statements.
  # Each import is converted to a proper `import module, only: functions` statement.
  #
  # ## Parameters
  #
  # - `params` - Atomized parameters map containing `:imports` key
  #
  # ## Returns
  #
  # Returns a tuple `{params, escaped_imports}` where:
  # - `params` - Original parameters (passed through)
  # - `escaped_imports` - Macro-escaped AST for all import statements
  #
  # ## Import Processing
  #
  # Each `{module, functions}` tuple in `:imports` is converted to:
  # ```elixir
  # import Module, only: [function: arity, ...]
  # ```
  #
  # The imports are macro-escaped to ensure proper expansion in the final AST.
  defp build_imports(params) do
    imports_ast =
      Enum.map(params[:imports] || [], fn {module, functions} ->
        quote do
          import unquote(module), only: unquote(functions)
        end
      end)

    escaped_imports = Macro.escape(imports_ast)

    {params, escaped_imports}
  end

  # Create the final module AST with __using__ macro.
  #
  # Assembles the complete module AST that contains a `__using__` macro which
  # expands to include all the configured import statements.
  #
  # ## Parameters
  #
  # - `{params, escaped_imports}` - Tuple containing:
  #   - `params` - Configuration map with `:module_name`
  #   - `escaped_imports` - Escaped AST for import statements
  #
  # ## Returns
  #
  # Returns the complete module AST ready for compilation.
  #
  # ## Generated Module Structure
  #
  # ```elixir
  # defmodule ModuleName do
  #   defmacro __using__(_) do
  #     quote do
  #       import Module1, only: [...]
  #       import Module2, only: [...]
  #       # ... more imports
  #     end
  #   end
  # end
  # ```
  #
  # The `__using__` macro allows other modules to `use ModuleName` and automatically
  # receive all configured imports.
  defp create_module_ast({params, escaped_imports}) do
    quote do
      defmodule unquote(params[:module_name]) do
        defmacro __using__(_) do
          imports = unquote(escaped_imports)

          quote do
            (unquote_splicing(imports))
          end
        end
      end
    end
  end
end
