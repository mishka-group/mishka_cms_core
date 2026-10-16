# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.SequenceTest do
  @moduledoc """
  A number that says which one of these this is, kept in step when another arrives.

  `chelekom-stepper-section` declares `step_number` with a default of 1 and the stepper's own
  furnishing writes 1, 2, 3 — so a fourth section dropped beside them said 1, and a duplicate of the
  second made two 2s. The author could edit the title and watch it change, and had nothing to change
  the number with: "it doesnt matter how many of them we have they alwas will show the number 1".

  ## What must NOT happen

  The dangerous half of a rule like this is the false positive: a component rewritten because three
  numbers happened to sit near each other. So a sequence has to be one — every sibling holding an
  integer literal, and those integers a consecutive ascending run. Three ones are three components
  nobody numbered. `{@index}` is the author binding it to their own data. Both are left alone, and
  both are asserted here.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Sequence
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @moduletag :unit

  @entry %{
    name: "acme-step",
    attrs: [
      %{"name" => "step_number", "type" => "integer", "opts" => %{"default" => 1}},
      %{"name" => "title", "type" => "string", "opts" => %{}}
    ]
  }

  defp built(markup) do
    {:ok, tree} = Tree.parse(markup)
    tree
  end

  defp steps(tree) do
    for node <- Tree.walk(tree),
        node.kind == :component,
        do: Node.attr(node, "step_number")
  end

  defp arriving(tree, index) do
    tree
    |> Tree.walk()
    |> Enum.filter(&(&1.kind == :component))
    |> Enum.at(index)
    |> Map.fetch!(:id)
  end

  defp markup(numbers) do
    written =
      Enum.map_join(numbers, "", fn
        nil -> ~s(<.component component_name="acme-step" />)
        value -> ~s(<.component component_name="acme-step" step_number={#{value}} />)
      end)

    "<div>" <> written <> "</div>"
  end

  describe "a run of siblings" do
    test "the one that arrived at the end continues it" do
      tree = built(markup([1, 2, 3, nil]))

      assert Sequence.settle(tree, arriving(tree, 3), [@entry]) |> steps() ==
               [{:expr, "1"}, {:expr, "2"}, {:expr, "3"}, {:expr, "4"}]
    end

    test "and one that arrived in the middle pushes the rest along" do
      tree = built(markup([1, 2, nil, 3]))

      assert Sequence.settle(tree, arriving(tree, 2), [@entry]) |> steps() ==
               [{:expr, "1"}, {:expr, "2"}, {:expr, "3"}, {:expr, "4"}]
    end

    # A DUPLICATE IS THE SAME PROBLEM WEARING A NUMBER. It copies the value it was made from, so the
    # run has two 2s in it until the arriving one is renumbered.
    test "a duplicate stops being a second copy of the number it came from" do
      tree = built(markup([1, 2, 2, 3]))

      assert Sequence.settle(tree, arriving(tree, 2), [@entry]) |> steps() ==
               [{:expr, "1"}, {:expr, "2"}, {:expr, "3"}, {:expr, "4"}]
    end

    test "a run that does not start at one is continued from where it does" do
      tree = built(markup([7, 8, nil]))

      assert Sequence.settle(tree, arriving(tree, 2), [@entry]) |> steps() ==
               [{:expr, "7"}, {:expr, "8"}, {:expr, "9"}]
    end
  end

  describe "what it refuses to touch" do
    test "numbers that are not a run" do
      for numbers <- [[1, 1, 1], [10, 20], [3, 1, 2]] do
        tree = built(markup(numbers ++ [nil]))
        before = steps(tree)

        assert Sequence.settle(tree, arriving(tree, length(numbers)), [@entry]) |> steps() ==
                 before,
               "#{inspect(numbers)} is not a sequence and was rewritten anyway"
      end
    end

    test "a number bound to the author's own data" do
      tree =
        built(
          ~s(<div><.component component_name="acme-step" step_number={@i} />) <>
            ~s(<.component component_name="acme-step" /></div>)
        )

      assert Sequence.settle(tree, arriving(tree, 1), [@entry]) |> steps() == [{:expr, "@i"}, nil]
    end

    test "a component standing on its own" do
      tree = built(markup([nil]))

      assert Sequence.settle(tree, arriving(tree, 0), [@entry]) |> steps() == [nil]
    end

    test "a sibling of another name" do
      tree =
        built(
          ~s(<div><.component component_name="acme-other" step_number={1} />) <>
            ~s(<.component component_name="acme-step" /></div>)
        )

      assert Sequence.settle(tree, arriving(tree, 1), [@entry]) |> steps() == [{:expr, "1"}, nil]
    end

    # Only `integer` and `pos_integer`. A float is a measurement and a string of digits is a label.
    test "an attribute the component did not declare as a whole number" do
      entry = %{
        name: "acme-step",
        attrs: [%{"name" => "step_number", "type" => "string", "opts" => %{}}]
      }

      tree = built(markup([1, 2, nil]))

      assert Sequence.settle(tree, arriving(tree, 2), [entry]) |> steps() ==
               [{:expr, "1"}, {:expr, "2"}, nil]
    end

    test "and a node the palette has never heard of" do
      tree = built(markup([1, 2, nil]))

      assert Sequence.settle(tree, arriving(tree, 2), []) |> steps() ==
               [{:expr, "1"}, {:expr, "2"}, nil]
    end
  end

  describe "against the kit" do
    @bundle MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

    # MOST WHOLE NUMBERS IN THE KIT ARE MEASUREMENTS, not positions — an image's width, a tooltip's
    # delay, a clipboard's timeout. That is the reason for the two-sibling rule, and it is measured
    # here rather than assumed so a kit that changes shape says so.
    test "whole-number attributes are mostly measurements, which is what the rule is careful of" do
      components = @bundle |> File.read!() |> Jason.decode!() |> Map.fetch!("components")

      numeric =
        for entry <- components,
            attr <- entry["attrs"] || [],
            attr["type"] in ~w(integer pos_integer),
            do: "#{entry["name"]}.#{attr["name"]}"

      assert "chelekom-stepper-section.step_number" in numeric
      assert "chelekom-image.width" in numeric
      assert "chelekom-clipboard.timeout" in numeric
    end

    # ONE NUMBER IS NOT COUNTING. Two images side by side, the first `width={100}`, would otherwise
    # have made the second 101.
    test "one sibling holding a number is not a sequence" do
      tree = built(markup([100, nil]))

      assert Sequence.settle(tree, arriving(tree, 1), [@entry]) |> steps() == [
               {:expr, "100"},
               nil
             ]
    end
  end
end
