# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Compilers.UndefinedModuleError do
  @moduledoc false

  @doc """
  Handles undefined function calls by attempting to ensure the module is loaded.

  This function is called when an undefined function is encountered. It first
  attempts to load the module and then delegates to the default error handler.
  """
  def undefined_function(module, fun, args) do
    ensure_loaded(module)
    :error_handler.undefined_function(module, fun, args)
  end

  @doc """
  Handles undefined lambda calls by attempting to ensure the module is loaded.

  This function is called when an undefined lambda is encountered. It first
  attempts to load the module and then delegates to the default error handler.
  """
  def undefined_lambda(module, fun, args) do
    ensure_loaded(module)
    :error_handler.undefined_lambda(module, fun, args)
  end

  @doc """
  Enables the custom error handler for the current process.

  This function configures the current process to use the MishkaCms custom error
  handler and stores the site configuration in the process dictionary.
  """
  def enable(site) do
    Process.put(:__mishka_cms__, site)
    Process.flag(:error_handler, MishkaCmsCore.Runtime.Compilers.UndefinedModuleError)
  end

  ####################################################################################
  ############################ (▰˘◡˘▰) Helpers (▰˘◡˘▰) ###############################
  ####################################################################################

  # Ensures a module is loaded in the code server. Attempts to load the specified module if it's not already loaded.
  defp ensure_loaded(module) do
    case :code.ensure_loaded(module) do
      {:module, _} -> true
      {:error, _} -> false
    end
  end
end
