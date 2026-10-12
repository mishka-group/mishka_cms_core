defmodule Mix.Tasks.MishkaCmsCore.Gettext.Gervaz do
  @shortdoc "Adds MishkaGervaz's messages to the core's .pot files"

  @moduledoc """
  Adds every message of MishkaGervaz's `.pot` files to the core's `.pot` file of the same domain.

  A host sets `config :mishka_gervaz, :gettext_backend, MishkaCmsCore.Gettext`, so MishkaGervaz's
  own words are translated from the core's `.po` files. `mix gettext.extract` finds only the core's
  own messages, so run this after it and merge the templates into the `.po` files again:

      mix gettext.extract --merge --no-fuzzy
      mix mishka_cms_core.gettext.gervaz
      mix mishka_cms_core.gettext.extensions
      mix gettext.merge priv/gettext --no-fuzzy

  A message the core writes too is left as it is. Any other keeps its references into MishkaGervaz,
  beside those of the extensions, which the project's `:excluded_refs_from_purging` keeps through
  the next `mix gettext.extract`, so `mix gettext.extract --check-up-to-date` still passes. A
  message neither MishkaGervaz nor an extension has any longer is removed. See
  `Mix.MishkaCmsCore.GettextTemplates`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    root = Map.fetch!(Mix.Project.deps_paths(), :mishka_gervaz)

    templates =
      root
      |> Path.join("priv/gettext/*.pot")
      |> Path.wildcard()
      |> Map.new(&{Path.basename(&1), Expo.PO.parse_file!(&1)})

    Mix.MishkaCmsCore.GettextTemplates.merge(File.cwd!(), root, templates)
  end
end
