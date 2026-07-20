defmodule MishkaCmsCore.Runtime.PageBuilder.NestedMenuTest do
  @moduledoc """
  A menu can hold a menu, and until now nothing in the editor said how.

  ## What was missing

  `chelekom-menu` renders a sub-menu when a `menu_items` entry carries `sub_items` — it wraps that
  entry in a `chelekom-collapse` and recurses into itself. Every example the kit shipped was FLAT,
  built out of `<li>` children, so an author browsing the palette saw one shape and had no way to
  discover the other. The report was exactly that: "menu or mega menu can be nested but ... even me
  i do not know how can done this".

  ## Why nesting could have failed quietly

  `menu_items` is a list attribute, so nesting is written as a literal — a list of maps, each with
  its own list of maps. `CanvasLive.literal/1` walks a quoted attribute rather than evaluating it,
  and it accepts containers of literals only; anything it refuses is DROPPED, which for this
  component means a menu that renders its top level and silently loses every sub-menu under it.

  So the example is pinned here twice over: that it parses as one component with the attribute
  written as an expression, and that the expression folds all the way down to the nested maps the
  component reads.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive

  @moduletag :unit

  @bundle Path.join([:code.priv_dir(:mishka_cms_core), "cms_ui_kits", "chelekom.json"])

  defp component(name) do
    @bundle
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("components")
    |> Enum.find(&(&1["name"] == name))
  end

  defp nested_example(name) do
    component(name)["examples"]
    |> Enum.find(&String.contains?(&1, "sub_items:"))
  end

  defp menu_items(source) do
    {:ok, tree} = Tree.parse(source)

    tree
    |> Tree.walk()
    |> Enum.find_value(fn node ->
      case Node.attr(node, "menu_items") do
        {:expr, expression} -> expression
        _other -> nil
      end
    end)
  end

  describe "chelekom-menu" do
    test "ships an example that nests, so the shape is discoverable from the palette" do
      assert nested_example("chelekom-menu"),
             "no chelekom-menu example shows a sub-menu — nesting is undiscoverable again"
    end

    test "the nested attribute folds to the maps the component reads, rather than being dropped" do
      {:ok, items} = nested_example("chelekom-menu") |> menu_items() |> CanvasLive.literal()

      assert is_list(items)

      parent = Enum.find(items, &Map.has_key?(&1, :sub_items))
      assert parent, "the example's menu_items carries no entry with sub_items"

      assert is_list(parent.sub_items)
      assert length(parent.sub_items) >= 2

      # Every leaf is a real link, which is what makes the sub-menu usable rather than decorative.
      for item <- parent.sub_items do
        assert is_binary(item.title)
        assert is_binary(item.navigate)
      end
    end

    # A SUB-MENU IS COLLAPSED BY ITS PARENT, and the parent builds that collapse's id from the
    # entry's own `id`. An entry without one renders a collapse called `-collapse`, and two of them
    # collide — which is the same duplicate-id fault the editor now renumbers for placed elements
    # and cannot renumber inside a literal attribute.
    test "every entry names itself, so the collapse ids it generates are distinct" do
      {:ok, items} = nested_example("chelekom-menu") |> menu_items() |> CanvasLive.literal()

      ids = for item <- items, do: item.id
      nested_ids = for item <- items, sub <- Map.get(item, :sub_items, []), do: sub.id

      all = ids ++ nested_ids

      assert Enum.all?(all, &(is_binary(&1) and &1 != ""))
      assert Enum.uniq(all) == all, "two entries share an id: #{inspect(all -- Enum.uniq(all))}"
    end
  end

  describe "chelekom-mega-menu" do
    test "ships an example holding a nested menu, which is how one column expands in place" do
      example = nested_example("chelekom-mega-menu")

      assert example, "no chelekom-mega-menu example nests a menu inside its panel"
      assert String.contains?(example, ~s(component_name="chelekom-menu"))

      assert String.contains?(example, "<:trigger>"),
             "a mega menu is opened by its own trigger slot"
    end

    test "the nested menu inside it folds the same way" do
      {:ok, items} = nested_example("chelekom-mega-menu") |> menu_items() |> CanvasLive.literal()

      assert Enum.any?(items, &Map.has_key?(&1, :sub_items))
    end
  end

  # THE EDITOR HAS TO BE ABLE TO OPEN THE EXAMPLE, not just render it. Both are placed as one
  # component with children, so the layers rail shows the structure an author then edits.
  test "each nested example parses into a tree the editor can walk" do
    for name <- ~w(chelekom-menu chelekom-mega-menu) do
      assert {:ok, tree} = name |> nested_example() |> Tree.parse()

      components =
        tree
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :component))
        |> Enum.map(&Node.component_name/1)

      assert name in components, "#{name}'s own example does not contain #{name}"
    end
  end
end
