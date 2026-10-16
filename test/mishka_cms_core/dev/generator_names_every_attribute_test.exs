# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Dev.GeneratorNamesEveryAttributeTest do
  @moduledoc """
  Every generator in `MishkaCmsCore.Dev.Generator` names every attribute its action accepts.

  An attribute a generator says nothing about is INVENTED by `Ash.Generator` from its type, and what
  the type allows is not what the resource accepts. The reported case: `dev_layout_with_tenant/2`
  and `dev_layout_global/1` never named `example`, so Ash drew one from all of printable Unicode.
  Its constraint — `min_length: 3, trim?: true` — takes a three-character string with a combining
  mark or a format character in it; the layout's guard strips zero-width and control characters and
  counts what is left before its `min_len=3`, and refuses it. So `Seeds.run/1` failed now and then,
  about one run of `test/mishka_cms/install/dev_seeds_test.exs` in three, in whichever test drew one.

  Read from the source, not sampled. A rejection like that came up three times in six thousand
  draws, which no sampling test finds on purpose, and a boolean coin flip or a garbage `uploads` list
  is never rejected at all — it is just wrong data. What IS certain is the list of names, so that is
  what is asserted: a new attribute on a resource fails here, naming the generator, instead of
  surfacing as a flaky seed.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Dev.Generator

  defp generators do
    source = :compile |> Generator.module_info() |> Keyword.fetch!(:source) |> to_string()
    {:ok, ast} = source |> File.read!() |> Code.string_to_quoted()

    {_ast, {_current, found}} =
      Macro.prewalk(ast, {nil, []}, fn
        {:def, _, [{name, _, args} | _]} = node, {_current, found} when is_atom(name) ->
          {node, {"#{name}/#{length(args || [])}", found}}

        {:changeset_generator, _, [resource, action, opts]} = node, {current, found} ->
          {node, {current, [{current, Macro.expand(resource, __ENV__), action, opts} | found]}}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp named(fun, opts) do
    defaults = Keyword.get(opts, :defaults, [])

    unless Keyword.keyword?(defaults) do
      flunk("#{fun}: `defaults` is not a literal keyword list, so what it names cannot be read")
    end

    Keyword.keys(defaults)
  end

  test "every generator in the module is read" do
    funs = Enum.map(generators(), &elem(&1, 0))

    assert "dev_layout_with_tenant/2" in funs
    assert "dev_layout_global/1" in funs
    assert length(funs) >= 16, "the source walk found only #{inspect(funs)}"
  end

  test "no generator leaves an accepted attribute for Ash to invent" do
    unnamed =
      for {fun, resource, action, opts} <- generators(),
          attribute <- Ash.Resource.Info.action(resource, action).accept -- named(fun, opts),
          do: "#{fun} → #{inspect(resource)}.#{attribute}"

    assert unnamed == [],
           "these are invented at random on every call — name each one:\n" <>
             Enum.join(unnamed, "\n")
  end

  # THE REPORTED CASE, asserted on what the generator actually produces.
  test "a seeded layout's example is never invented" do
    tenant = Ecto.UUID.generate()

    for generator <- [Generator.dev_layout_with_tenant([], tenant), Generator.dev_layout_global()],
        _draw <- 1..300 do
      assert generator |> Enum.at(0) |> Ash.Changeset.get_attribute(:example) == nil
    end
  end
end
