# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.MishkaCmsCore.Gettext.Extensions do
  @shortdoc "Adds the extensions' messages to the core's .pot files"

  @moduledoc """
  Adds every message the extensions mark with `MishkaCmsCore.Gettext` to the core's `.pot` file of
  its domain.

  An extension writes `use Gettext, backend: MishkaCmsCore.Gettext`, so its words are translated
  from the core's `.po` files. `mix gettext.extract` writes the templates of the backends of the
  project it runs in only, so run this in the core after it, with the extensions checked out beside
  the core, and merge the templates into the `.po` files again:

      mix gettext.extract --merge --no-fuzzy
      mix mishka_cms_core.gettext.gervaz
      mix mishka_cms_core.gettext.extensions
      mix gettext.merge priv/gettext --no-fuzzy

  With no arguments it reads `../mishka_blog` and `../mishka_document`. Give the paths of the
  extensions to read others:

      mix mishka_cms_core.gettext.extensions ../mishka_blog ../mishka_document ../my_extension

  In each one it runs this task again, in the `dev` environment and with `--core` naming the core.
  There the task compiles the extension with Gettext's extractor on, through `mix gettext.extract`,
  and writes what its `gettext`, `dgettext`, `ngettext`, `*_noop` and other Gettext macros mark with
  `MishkaCmsCore.Gettext` into the core's templates: every domain, plural forms, the text a HEEx
  template or a MishkaGervaz DSL option marks, and the reference of each mark. Run in an extension
  by hand, it writes into the `:mishka_cms_core` dependency, or into the core `--core` names:

      mix mishka_cms_core.gettext.extensions --core ../mishka_cms_core

  A message the core writes too is left as it is. Any other keeps its references into the extension,
  beside those of MishkaGervaz and the other extensions, which the project's
  `:excluded_refs_from_purging` keeps through the next `mix gettext.extract`, so
  `mix gettext.extract --check-up-to-date` still passes. A message neither an extension nor
  MishkaGervaz has any longer is removed. See `Mix.MishkaCmsCore.GettextTemplates`.
  """
  use Mix.Task

  alias Mix.MishkaCmsCore.GettextTemplates

  @extensions ["../mishka_blog", "../mishka_document"]

  @impl Mix.Task
  def run(args) do
    {opts, paths} = OptionParser.parse!(args, strict: [core: :string])
    run_in(Mix.Project.config()[:app], opts, paths)
  end

  defp run_in(:mishka_cms_core, _opts, []), do: run_in(:mishka_cms_core, [], @extensions)

  defp run_in(:mishka_cms_core, _opts, paths) do
    core = File.cwd!()
    Enum.each(paths, &read_extension(&1, core))
  end

  defp run_in(_extension, opts, []), do: extract(opts[:core] || dependency_core())

  defp run_in(_extension, _opts, paths),
    do: Mix.raise("Paths are read from the core only, got: #{Enum.join(paths, " ")}")

  # Runs the task in the extension at `path`, which writes its messages into `core`.
  defp read_extension(path, core) do
    unless File.regular?(Path.join(path, "mix.exs")) do
      Mix.raise("No Mix project at #{path}; give the paths of the extensions to read")
    end

    Mix.shell().info("Reading the messages of #{path}")

    case System.cmd("mix", ["mishka_cms_core.gettext.extensions", "--core", core],
           cd: path,
           env: [{"MIX_ENV", "dev"}],
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("Reading the messages of #{path} exited with #{status}")
    end
  end

  # Compiles the current project with Gettext's extractor on and writes what it marks with the
  # core's backend into the core's templates.
  defp extract(core) do
    Mix.Task.rerun("gettext.extract")

    templates =
      [MishkaCmsCore.Gettext]
      |> Gettext.ExtractorAgent.pop_message()
      |> Map.get(MishkaCmsCore.Gettext, %{})
      |> Map.new(fn {domain, messages} -> {"#{domain}.pot", template(messages)} end)

    GettextTemplates.merge(core, File.cwd!(), templates)
  end

  defp template(messages) do
    %Expo.Messages{messages: messages |> Map.values() |> Enum.sort_by(&Expo.Message.key/1)}
  end

  defp dependency_core do
    case Mix.Project.deps_paths() do
      %{mishka_cms_core: core} ->
        core

      _deps ->
        Mix.raise("This project has no :mishka_cms_core dependency; give the core with --core")
    end
  end
end
