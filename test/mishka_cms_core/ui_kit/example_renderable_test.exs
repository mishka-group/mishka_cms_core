# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.ExampleRenderableTest do
  @moduledoc """
  Every example of every installed kit must SURVIVE the canvas, not merely parse.

  The bug this exists for: `chelekom-flash-group` declares `flash` required with no default and its
  template reads `@flash`, so the example writes `flash={%{}}` — the only way to write an empty map.
  `CanvasLive` resolved attribute expressions with a scalar-only test, dropped the map, and then its
  required-attribute guard still counted the attribute as supplied because it *was* written. The
  assign never arrived, `@flash` raised `KeyError` inside LiveView's diff, and the modal answered 500.

  Parsing was never the question — that example parsed perfectly. What matters is whether every
  attribute the component cannot live without actually REACHES it.

  Reading the bundle rather than the database is deliberate: it is the shipped contract, it needs no
  Postgres, and it covers whatever kits are installed.
  """

  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive

  @moduletag :unit

  @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()

  setup_all do
    components =
      @kits_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path |> File.read!() |> Jason.decode!() |> Map.get("components", [])
      end)

    {:ok, components: components, by_name: Map.new(components, &{&1["name"], &1})}
  end

  # The CANVAS's own function, not a copy of its rule. A restatement would keep passing if the canvas
  # narrowed what it resolves, which is exactly the drift that produced the 500.
  defp resolvable?(source), do: match?({:ok, _value}, CanvasLive.literal(source))

  defp required_names(component) do
    component
    |> Map.get("attrs", [])
    |> Enum.filter(fn attr ->
      opts = Map.get(attr, "opts") || %{}

      Map.get(opts, "required") in [true, "true"] and is_nil(Map.get(opts, "default")) and
        Map.get(attr, "type") not in ["global", "struct"]
    end)
    |> Enum.map(&Map.get(&1, "name"))
  end

  # Every `<.component>` node in the example, whatever depth it sits at — a finished block composes,
  # and a required attribute missing on a nested child kills the render just as surely.
  defp component_nodes(tree) do
    tree |> Tree.walk() |> Enum.filter(&(&1.kind == :component and &1.tag == ".component"))
  end

  defp sources(component) do
    examples = get_in(component, ["extra", "examples"]) || []
    furnishing = get_in(component, ["extra", "furnishing"]) || %{}

    for {label, source} <-
          [{"furnishing", furnishing["body"]}] ++
            for(e <- examples, do: {e["label"], e["source"]}),
        is_binary(source),
        String.trim(source) != "",
        do: {label, source}
  end

  describe "every example the modal can show" do
    test "the kits are actually there to check", %{components: components} do
      assert length(components) >= 100
    end

    test "parses as a tree the editor can place", %{components: components} do
      broken =
        for component <- components,
            {label, source} <- sources(component),
            match?({:error, _reason}, Tree.parse(source)),
            do: "#{component["name"]} — #{label}"

      assert broken == [], "these place nothing at all:\n" <> Enum.join(broken, "\n")
    end

    # THE ONE THAT CATCHES THE 500. A required attribute is only supplied if the canvas can resolve
    # its value: written-but-unresolvable is worse than absent, because the guard lets it through.
    test "every required attribute actually reaches its component", %{
      components: components,
      by_name: by_name
    } do
      dropped =
        for component <- components,
            {label, source} <- sources(component),
            {:ok, tree} = Tree.parse(source),
            node <- component_nodes(tree),
            name = Node.component_name(node),
            declared = by_name[name],
            not is_nil(declared),
            required <- required_names(declared),
            written = Node.attr(node, required),
            not supplied?(written),
            do: "#{component["name"]} — #{label}: <#{name}> #{required} #{describe(written)}"

      assert dropped == [],
             "the canvas drops these before the component sees them, and the render raises:\n" <>
               Enum.join(dropped, "\n")
    end
  end

  defp supplied?({:string, value}), do: String.trim(value) != ""
  defp supplied?({:expr, source}), do: resolvable?(source)
  defp supplied?(nil), do: false
  defp supplied?(_boolean), do: true

  defp describe(nil), do: "is missing"
  defp describe({:string, ""}), do: "is blank"
  defp describe({:expr, source}), do: "is {#{source}}, which the canvas cannot resolve"
  defp describe(other), do: "is #{inspect(other)}"
end
