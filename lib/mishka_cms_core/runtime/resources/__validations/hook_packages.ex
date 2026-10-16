# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Resources.Validations.HookPackages do
  @moduledoc """
  A JS hook's `npm` packages and `modules` are what the JavaScript compiler fetches and writes to
  disk, so a hook is refused unless each package is one
  `MishkaCmsCore.Runtime.Compilers.NpmPackages` can fetch, and each module a plain `name.js` with
  its content — written beside the hook, and nowhere else.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use Ash.Resource.Validation

  alias MishkaCmsCore.Runtime.Compilers.NpmPackages

  @module_file ~r/^[A-Za-z0-9][A-Za-z0-9_-]*\.js$/

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    npm = Ash.Changeset.get_attribute(changeset, :npm) || []
    modules = Ash.Changeset.get_attribute(changeset, :modules) || []

    cond do
      not Enum.all?(npm, &NpmPackages.valid_entry?/1) ->
        {:error,
         field: :npm,
         message:
           dgettext_noop(
             "errors",
             "Each package needs an npm name, an exact version, its path in node_modules and a sha512 integrity hash."
           )}

      not Enum.all?(modules, &module?/1) ->
        {:error,
         field: :modules,
         message:
           dgettext_noop("errors", "Each module needs a file name like name.js and its content.")}

      true ->
        :ok
    end
  end

  @doc "Whether `module` is a file the compiler may write beside a hook."
  @spec module?(term()) :: boolean()
  def module?(module) do
    case NpmPackages.stringify(module) do
      %{"file" => file, "content" => content} when is_binary(file) and is_binary(content) ->
        Regex.match?(@module_file, file)

      _not_a_module ->
        false
    end
  end
end
