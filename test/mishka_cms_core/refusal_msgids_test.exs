# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.RefusalMsgidsTest do
  @moduledoc """
  Every fixed refusal the core writes is a msgid of its `errors` Gettext domain.

  A refusal is a message an action stores on an error: the `message` of a `validate`, an `identity`
  or a `check_constraint`, a `:message` inside an `{:error, …}` a validation returns or an error's
  `exception/1` builds, and a sentence a validation returns or `add_error/2` adds. Written with
  `dgettext_noop("errors", …)` it is found by `mix gettext.extract --merge`; one that is not in
  `priv/gettext/errors.pot` is a sentence no translator is given.

  The sources are read, not the compiled resources: most refusals are inside anonymous functions
  and validation modules no introspection reaches.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @pot Path.join(@root, "priv/gettext/errors.pot")

  @contexts [
    :validate,
    :atomic,
    :exception,
    :add_error,
    :identity,
    :check_constraint,
    :error_tuple
  ]
  @validation_contexts [:validate, :atomic, :add_error]
  @gettext [:dgettext, :dgettext_noop, :dngettext, :dngettext_noop, :dpgettext, :dpgettext_noop]

  test "every refusal is a msgid of the errors domain" do
    msgids =
      @pot
      |> Expo.PO.parse_file!()
      |> Map.fetch!(:messages)
      |> MapSet.new(&IO.iodata_to_binary(&1.msgid))

    missing =
      for {file, line, text} <- refusals(),
          is_binary(text) and not MapSet.member?(msgids, text),
          uniq: true,
          do: "#{file}:#{line} #{inspect(text)}"

    assert missing == [],
           "refusals missing from priv/gettext/errors.pot; wrap each in " <>
             "dgettext_noop(\"errors\", …) and run mix gettext.extract --merge:\n" <>
             Enum.map_join(missing, "\n", &("  " <> &1))
  end

  defp refusals do
    for file <- Path.wildcard(Path.join(@root, "lib/**/*.ex")),
        source = File.read!(file),
        value <- source |> Code.string_to_quoted!() |> collect() |> Enum.reverse(),
        text <- texts(value) do
      {Path.relative_to(file, @root), line_of(source, text), text}
    end
  end

  defp line_of(source, {:interpolated, "", last}), do: line_of(source, last)
  defp line_of(source, {:interpolated, first, _last}), do: line_of(source, first)
  defp line_of(_source, ""), do: "?"

  defp line_of(source, text) do
    case :binary.match(source, text) do
      {at, _length} -> source |> binary_part(0, at) |> String.split("\n") |> length()
      :nomatch -> "?"
    end
  end

  defp texts(text) when is_binary(text), do: [text]
  defp texts({name, _meta, [_domain, msgid | _]}) when name in @gettext, do: texts(msgid)

  defp texts({:<<>>, _meta, parts}) do
    [{:interpolated, literal(List.first(parts)), literal(List.last(parts))}]
  end

  defp texts(_expression), do: []

  defp literal(part) when is_binary(part), do: part
  defp literal(_expression), do: ""

  defp collect(ast) do
    {_ast, {_stack, found}} = Macro.traverse(ast, {[], []}, &enter/2, &leave/2)
    found
  end

  defp enter(node, {stack, found}) do
    found = found(node, stack) ++ found
    {node, {push(node, stack), found}}
  end

  defp leave(node, {stack, found}) do
    case context(node) do
      nil -> {node, {stack, found}}
      _context -> {node, {tl(stack), found}}
    end
  end

  defp push(node, stack) do
    case context(node) do
      nil -> stack
      context -> [context | stack]
    end
  end

  defp context({kind, _meta, [{name, _, _} | _]}) when kind in [:def, :defp] and is_atom(name),
    do: name

  defp context({:error, value}) when is_list(value), do: :error_tuple
  defp context({{:., _, [_module, name]}, _meta, args}) when is_list(args), do: name
  defp context({name, _meta, args}) when is_atom(name) and is_list(args), do: name
  defp context(_node), do: nil

  defp found({:message, value}, stack) do
    if Enum.any?(stack, &(&1 in @contexts)), do: [value], else: []
  end

  defp found({:message, _meta, [value]}, stack) do
    if :validate in stack, do: [value], else: []
  end

  defp found({:error, value}, stack) when is_binary(value) do
    if Enum.any?(stack, &(&1 in @validation_contexts)), do: [value], else: []
  end

  defp found({:add_error, _meta, [_changeset, value]}, _stack) when is_binary(value),
    do: [value]

  defp found({{:., _meta, [_module, :add_error]}, _, [_changeset, value]}, _stack)
       when is_binary(value),
       do: [value]

  defp found(_node, _stack), do: []
end
