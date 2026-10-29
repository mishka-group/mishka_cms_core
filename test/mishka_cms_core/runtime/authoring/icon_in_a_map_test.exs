# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.IconInAMapTest do
  @moduledoc """
  A label is not always a word, and a count of zero is not a component.

  Dropping a `chelekom-pagination` gave an author a strip with no pages on it and two empty boxes
  where its arrows should be, and an Inspector with no way to change either. Three separate causes,
  none of them about colour, which is what it was reported as.

  ## The count

  Placement leaves a required STRING empty on purpose: the Inspector marks it Required and the save
  refuses until it is filled. A number has no empty — `blank_attr?/2` reads the text "0" as filled —
  so a numeric seed is a value nobody is ever told to replace, and zero is the one number that can
  render as nothing. `chelekom-pagination` builds `range(1, total)`, which for zero is the empty
  list.

  ## The arrows

  The canvas generates a CSS rule for every icon the document could draw, because the site's own
  stylesheet only carries the ones its pages already render. It looked for those names in
  `{:string, …}` attributes — and pagination's five arrows and its separator are declared as `map`,
  each defaulting to `%{type: :icon, value: "hero-chevron-left"}`, which the bundle carries as an
  `__atom_map__` envelope. No rule was generated, so each drew an empty box.

  ## And no way to change them

  Read as a plain map attribute, each of those six drew a text box with nothing an author could
  usefully type into it. The widget is decided from the DECLARED DEFAULT rather than from the
  attribute's name, so a kit that spells the same idea differently is covered without being named —
  and the control writes the map back, because a component reading `Map.get(@previous_label, :type)`
  off a binary raises.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.Icons
  alias MishkaCmsCore.Runtime.Authoring.Inspector

  @moduletag :unit

  @bundle MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  setup_all do
    entries = @bundle |> File.read!() |> Jason.decode!() |> Map.fetch!("components")
    {:ok, entries: entries, by_name: Map.new(entries, &{&1["name"], &1})}
  end

  defp attr(entry, name), do: Enum.find(Inspector.attrs(entry), &(Inspector.name(&1) == name))

  describe "an icon carried in a map" do
    test "is recognised from what the component declared", %{by_name: by_name} do
      entry = by_name["chelekom-pagination"]

      for name <- ~w(previous_label next_label first_label last_label separator) do
        assert Inspector.icon_map?(attr(entry, name)), "#{name} is not seen as an icon"
        assert Inspector.widget(attr(entry, name), Inspector.features(entry), entry) == :icon
      end
    end

    test "and a map that is not one is left alone", %{by_name: by_name} do
      entry = by_name["chelekom-pagination"]

      refute Inspector.icon_map?(attr(entry, "params")), "an empty map is not an icon"
      refute Inspector.icon_map?(attr(entry, "total"))
    end

    test "reads its name out of every shape it arrives in" do
      assert Inspector.icon_in(%{"__atom_map__" => [[":type", ":icon"], [":value", "hero-star"]]}) ==
               "hero-star"

      assert Inspector.icon_in(%{type: :icon, value: "hero-star"}) == "hero-star"
      assert Inspector.icon_in(~S|%{type: :icon, value: "hero-star"}|) == "hero-star"

      assert Inspector.icon_in(%{type: :text, value: "Previous"}) == nil
      assert Inspector.icon_in("hero-star") == nil
      assert Inspector.icon_in(nil) == nil
      assert Inspector.icon_in("not elixir at all {{{") == nil
    end
  end

  describe "the icons a page could draw" do
    # `CanvasLive` walks a term for these; the names have to be findable wherever the kit puts them,
    # which is what the walk is for. Asserted against `Icons.known?/1`, the same question the walk
    # asks, so a kit shipping a set this install does not have is not a failure here.
    test "include the ones a component defaults to inside a map", %{by_name: by_name} do
      defaults =
        for attr <- Inspector.attrs(by_name["chelekom-pagination"]),
            name = Inspector.icon_in(Inspector.default(attr)),
            do: name

      assert length(defaults) == 5

      for name <- defaults do
        assert Icons.known?(name), "#{name} is not an icon any installed set ships"
        assert Icons.css([name]) != "", "no rule is generated, so it draws as an empty box"
      end
    end
  end
end
