defmodule Mix.MishkaCmsCore.GettextTemplates do
  @moduledoc """
  Writes messages marked outside the core into the core's `.pot` files, for
  `mix mishka_cms_core.gettext.gervaz` and `mix mishka_cms_core.gettext.extensions`.

  A source is a project and its templates by file name (`"default.pot"`), with references relative
  to that project. `merge/3` writes them into the core's `priv/gettext`:

    * a message with a reference into the core is left as it is, since `mix gettext.extract` writes
      its references;
    * any other message the source has gets the source's references, relative to the core, beside
      those of the other sources, and keeps its flags and comments while another source references
      it too; one no other source references is the source's own, and one the core's template lacks
      is added at its end;
    * a reference into the source that the source no longer has is removed, and with it a message no
      source references any longer.

  The core's `:excluded_refs_from_purging` matches every reference outside the core, so the next
  `mix gettext.extract` keeps what is written here, and `mix gettext.extract --check-up-to-date`
  still passes. A template that changes is written and named on the shell.
  """

  @target "priv/gettext"

  @new_template_comment String.split(
                          """
                          # This file is a PO Template file.
                          #
                          # "msgid"s here are often extracted from source code.
                          # Add new messages manually only if they're dynamic
                          # messages that can't be statically extracted.
                          #
                          # Run "mix gettext.extract" to bring this file up to
                          # date. Leave "msgstr"s empty as changing them here has no
                          # effect: edit them in PO (.po) files instead.
                          """,
                          "\n"
                        )

  @doc """
  Writes the `templates` of the project at `source` into the `.pot` files of the core at `core`.

  `templates` maps a template's file name to its `Expo.Messages`, with references relative to
  `source`. A reference outside `source` is left out. Every template of the core is visited, so the
  references of a domain the source no longer marks are removed too.
  """
  @spec merge(Path.t(), Path.t(), %{String.t() => Expo.Messages.t()}) :: :ok
  def merge(core, source, templates) do
    core = Path.expand(core)
    source = Path.expand(source)
    target = Path.join(core, @target)
    prefix = Path.relative_to(source, core, force: true) <> "/"

    sources =
      Map.new(templates, fn {file, messages} -> {file, relocate(messages, source, core)} end)

    target
    |> Path.join("*.pot")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.concat(Map.keys(sources))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&write(Path.join(target, &1), prefix, Map.get(sources, &1, [])))
  end

  # Writes one template when merging the source's messages into it changes it.
  defp write(path, prefix, messages) do
    template = read(path)
    merged = %{template | messages: merge_messages(template.messages, prefix, messages)}
    content = merged |> Expo.PO.compose() |> IO.iodata_to_binary()

    cond do
      File.exists?(path) and File.read!(path) == content -> :ok
      not File.exists?(path) and merged.messages == [] -> :ok
      true -> write!(path, content)
    end
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end

  defp read(path) do
    if File.exists?(path) do
      Expo.PO.parse_file!(path)
    else
      %Expo.Messages{headers: [""], top_comments: @new_template_comment, messages: []}
    end
  end

  # Keeps the template's order: each message is updated in place, and the source's messages the
  # template lacks follow at the end in the source's order.
  defp merge_messages(messages, prefix, source) do
    by_key = Map.new(source, &{Expo.Message.key(&1), &1})
    present = MapSet.new(messages, &Expo.Message.key/1)

    Enum.flat_map(messages, &update(&1, prefix, Map.get(by_key, Expo.Message.key(&1)))) ++
      Enum.reject(source, &MapSet.member?(present, Expo.Message.key(&1)))
  end

  # Returns the message with the source's references in place of its earlier ones, or nothing when
  # no reference is left of a message that had some. A message no other source references is the
  # source's own, flags and comments included.
  defp update(message, prefix, from_source) do
    references = references(message)
    others = Enum.reject(references, &String.starts_with?(file(&1), prefix))

    cond do
      Enum.any?(references, &core?/1) -> [message]
      from_source && others == [] -> [from_source]
      from_source -> [%{message | references: lines(others ++ references(from_source))}]
      others == references -> [message]
      others != [] -> [%{message | references: lines(others)}]
      true -> []
    end
  end

  # Rewrites each reference relative to the core, leaving out those outside the source and the
  # messages left with none.
  defp relocate(%Expo.Messages{messages: messages}, source, core) do
    Enum.flat_map(messages, fn message ->
      case message
           |> references()
           |> Enum.filter(&inside?/1)
           |> Enum.map(&relocate_reference(&1, source, core)) do
        [] -> []
        references -> [%{message | references: lines(references)}]
      end
    end)
  end

  defp references(message), do: List.flatten(message.references)

  defp relocate_reference({file, line}, source, core),
    do: {relocate_reference(file, source, core), line}

  defp relocate_reference(file, source, core),
    do: file |> Path.expand(source) |> Path.relative_to(core, force: true)

  defp lines(references), do: references |> Enum.uniq() |> Enum.sort() |> Enum.map(&[&1])

  defp inside?(reference) do
    file = file(reference)
    Path.type(file) == :relative and not String.starts_with?(file, "../")
  end

  defp core?(reference), do: not String.starts_with?(file(reference), "../")

  defp file({file, _line}), do: file
  defp file(file), do: file
end
