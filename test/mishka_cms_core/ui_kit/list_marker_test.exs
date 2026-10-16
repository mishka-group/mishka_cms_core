# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.UiKit.ListMarkerTest do
  @moduledoc """
  A marker is one of three things, so the Inspector has to offer three things.

  `style` on `chelekom-list` and `chelekom-ul` was declared as a bare string with no values and no
  doc, so the Inspector drew an unlabelled text box down in the leftovers and an author had to
  already know that the word for a bullet is `list-disc`. `chelekom-ol` had no such attribute at
  all — it hardcoded `list-decimal` into its class list.

  ## The rule, and why it is not a list of three words

  Each of those templates carries `[&.list-decimal]:ps-5 [&.list-disc]:ps-5`: padding that applies
  only WHEN the element has that class. A rule keyed on a class the component can never be given is
  dead code, and it is dead in the exact way that matters — it is the author-facing option that went
  missing, written down in the stylesheet and nowhere else.

  So the sweep asks the templates, not a word list: for every `[&.x]` a kit writes, something must
  be able to put `x` on the element — a literal in the template, a value the attribute declares, or
  a helper that emits it. On the bundle as it shipped before the fix this found `ul` unable to be
  either decimal or disc and `ol` unable to be disc; a kit adding a fourth marker, or a different
  kit entirely, is covered without a line changing here.
  """

  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Inspector

  @moduletag :unit

  @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()

  # `[&.list-disc]:ps-5` — a Tailwind rule that fires only when the element carries `list-disc`.
  @keyed_on_a_class ~r/\[&\.([A-Za-z0-9_-]+)\]/

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

  defp keyed_classes(template),
    do: @keyed_on_a_class |> Regex.scan(template) |> Enum.map(&List.last/1) |> Enum.uniq()

  # Everything the component can put on an element: its own markup and whatever its helpers return,
  # with the `[&.x]` selectors themselves removed so a rule cannot vouch for itself.
  defp emittable(component) do
    helpers =
      component
      |> Map.get("helpers", [])
      |> Enum.map_join(" ", &((&1["body"] || "") <> (&1["template"] || "")))

    String.replace((component["template"] || "") <> " " <> helpers, @keyed_on_a_class, " ")
  end

  defp declared_values(component) do
    for attr <- Map.get(component, "attrs", []),
        value <- get_in(attr, ["opts", "values"]) || [],
        is_binary(value),
        do: value,
        into: MapSet.new()
  end

  defp reachable?(component, class) do
    MapSet.member?(declared_values(component), class) or
      Regex.match?(~r/(?<![\w-])#{Regex.escape(class)}(?![\w-])/, emittable(component))
  end

  defp style_widget(component) do
    attr = Enum.find(Inspector.attrs(component), &(Inspector.name(&1) == "style"))
    attr && Inspector.widget(attr, Inspector.features(component), component)
  end

  describe "a style a rule is written for" do
    test "is a style the component can actually be given", %{components: components} do
      dead =
        for component <- components,
            class <- keyed_classes(component["template"] || ""),
            not reachable?(component, class),
            do: "#{component["name"]} styles .#{class}, and nothing can put .#{class} on it"

      assert dead == [], Enum.join(dead, "\n")
    end

    test "and the sweep is looking at rules that exist", %{components: components} do
      assert Enum.count(components, &(keyed_classes(&1["template"] || "") != [])) >= 1
    end
  end

  describe "the three list markers" do
    test "each list component offers all three, not a text box", %{by_name: by_name} do
      for name <- ~w(chelekom-list chelekom-ul chelekom-ol) do
        assert {:select, values} = style_widget(by_name[name]),
               "#{name} does not offer its marker as a choice"

        assert Enum.sort(values) == ["list-decimal", "list-disc", "list-none"]
      end
    end

    test "and each keeps the marker it always had", %{by_name: by_name} do
      defaults =
        Map.new(~w(chelekom-list chelekom-ul chelekom-ol), fn name ->
          attr = Enum.find(Inspector.attrs(by_name[name]), &(Inspector.name(&1) == "style"))
          {name, Inspector.default(attr)}
        end)

      assert defaults == %{
               "chelekom-list" => "list-none",
               "chelekom-ul" => "list-none",
               "chelekom-ol" => "list-decimal"
             }
    end
  end
end
