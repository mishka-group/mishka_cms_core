defmodule Mix.Tasks.MishkaCmsCore.Gettext.Gervaz do
  @shortdoc "Adds MishkaGervaz's messages to the core's .pot files"

  @moduledoc """
  Adds every message of MishkaGervaz's `.pot` files to the core's `.pot` file of the same domain.

  A host sets `config :mishka_gervaz, :gettext_backend, MishkaCmsCore.Gettext`, so MishkaGervaz's
  own words are translated from the core's `.po` files. `mix gettext.extract` finds only the core's
  own messages, so run this after it and merge the templates into the `.po` files again:

      mix gettext.extract --merge --no-fuzzy
      mix mishka_cms_core.gettext.gervaz
      mix gettext.merge priv/gettext --no-fuzzy

  A message the core writes too is left as it is. Any other keeps its references into MishkaGervaz,
  which the project's `:excluded_refs_from_purging` keeps through the next `mix gettext.extract`, so
  `mix gettext.extract --check-up-to-date` still passes. One MishkaGervaz no longer has is removed.
  """
  use Mix.Task

  @target "priv/gettext"

  @impl Mix.Task
  def run(_args) do
    root = Map.fetch!(Mix.Project.deps_paths(), :mishka_gervaz)

    for template <- Path.wildcard(Path.join(root, "priv/gettext/*.pot")) do
      target = Path.join(@target, Path.basename(template))
      gervaz = template |> Expo.PO.parse_file!() |> relocate(root)

      target
      |> read(gervaz)
      |> add(gervaz.messages)
      |> Expo.PO.compose()
      |> then(&File.write!(target, &1))

      Mix.shell().info("Wrote #{target}")
    end
  end

  defp read(target, gervaz) do
    if File.exists?(target) do
      target
      |> Expo.PO.parse_file!()
      |> Map.update!(:messages, fn messages -> Enum.flat_map(messages, &without_gervaz/1) end)
    else
      %{gervaz | messages: []}
    end
  end

  defp without_gervaz(%{references: [_ | _] = lines} = message) do
    case lines
         |> Enum.map(&Enum.reject(&1, fn ref -> gervaz?(ref) end))
         |> Enum.reject(&(&1 == [])) do
      [] -> []
      own -> [%{message | references: own}]
    end
  end

  defp without_gervaz(message), do: [message]

  defp add(%Expo.Messages{} = messages, gervaz_messages) do
    new = Enum.reject(gervaz_messages, &Expo.Messages.find(messages, &1))
    %{messages | messages: messages.messages ++ new}
  end

  defp relocate(%Expo.Messages{} = messages, root) do
    Map.update!(messages, :messages, fn messages ->
      Enum.map(messages, fn message ->
        Map.update!(message, :references, fn lines ->
          Enum.map(lines, fn line -> Enum.map(line, &relocate_reference(&1, root)) end)
        end)
      end)
    end)
  end

  defp relocate_reference({file, line}, root), do: {gervaz_path(file, root), line}
  defp relocate_reference(file, root), do: gervaz_path(file, root)

  defp gervaz_path(file, root),
    do: root |> Path.join(file) |> Path.relative_to(File.cwd!(), force: true)

  defp gervaz?({file, _line}), do: gervaz?(file)
  defp gervaz?(file), do: file =~ gervaz_references()

  defp gervaz_references do
    Mix.Project.config()
    |> Keyword.fetch!(:gettext)
    |> Keyword.fetch!(:excluded_refs_from_purging)
  end
end
