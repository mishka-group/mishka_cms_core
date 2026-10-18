# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.InteractiveSettingsTest do
  @moduledoc """
  Every component that opens can also be CONFIGURED, and the Inspector has to be able to draw the
  controls for it.

  ## The question this answers

  "How do I set up a popover?" — asked of a component whose whole surface is hidden until something
  opens it. Opening it is one half, and `MishkaCmsCore.Runtime.PageBuilder.OpenCommandTest` covers
  that. The other half is whether the panel an author lands on after clicking it is usable: whether
  the options the kit enumerates reach the Inspector as SELECTS rather than as free-text boxes,
  whether a value it will refuse can be typed in, and whether a required attribute is marked as one.

  ## Why it sweeps rather than lists

  Eleven components declare an opener today and the next kit will declare more. A test naming three
  of them passes forever while the eighth ships with `position` as a text box nobody can guess the
  values of. Everything here is derived from the shipped bundle, so a component is covered the
  moment it is in it.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.PaletteEntry
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.Interactions
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCoreWeb.Live.Admin.Builder.Panels

  @moduletag :unit

  @bundle MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  setup_all do
    components = @bundle |> File.read!() |> Jason.decode!() |> Map.fetch!("components")

    interactive = Enum.filter(components, &(PaletteEntry.opens(&1) != %{}))

    {:ok, components: components, interactive: interactive}
  end

  test "there are interactive components to check", %{interactive: interactive} do
    assert length(interactive) >= 10,
           "the sweep found nothing — every test here would vacuously pass"
  end

  # AN OPENER IS USELESS WITHOUT SOMETHING TO AIM AT. `JS.exec(…, to: …)` finds the element by a
  # selector, and every one of these builds its own commands from `@id`.
  test "each one takes an id, so a button can be aimed at it", %{interactive: interactive} do
    for component <- interactive do
      names = Enum.map(Inspector.attrs(component), &Inspector.name/1)

      assert "id" in names, "#{component["name"]} declares an opener but takes no id"
    end
  end

  # A TEXT BOX FOR AN ENUMERATED OPTION IS A GUESSING GAME. The kit knows `position` is one of six
  # words; if that list does not reach the Inspector the author types one and finds out later that
  # the component silently fell back to its default.
  test "an option the kit enumerates is offered as a choice, not typed", %{
    interactive: interactive
  } do
    for component <- interactive,
        features = Inspector.features(component),
        attribute <- Inspector.attrs(component),
        values = enumerated(attribute, features),
        values != [] do
      assert match?(
               {kind, _values} when kind in [:select, :segmented],
               Inspector.widget(attribute, features, component)
             ),
             "#{component["name"]}'s #{Inspector.name(attribute)} enumerates " <>
               "#{inspect(values)} but is drawn as " <>
               inspect(Inspector.widget(attribute, features, component))
    end
  end

  # A DEFAULT THE COMPONENT WOULD REFUSE reads as "this is what you get" and is not. Blank is
  # allowed and means something real — the component's own fallback, which the select offers as
  # "— default —" — but a NAMED default has to be one of the names on offer.
  test "every enumerated option's default is one of its own values", %{interactive: interactive} do
    for component <- interactive,
        features = Inspector.features(component),
        attribute <- Inspector.attrs(component),
        values = enumerated(attribute, features),
        values != [],
        default = Inspector.default(attribute),
        is_binary(default),
        String.trim(default) != "" do
      assert default in values,
             "#{component["name"]}'s #{Inspector.name(attribute)} defaults to #{default}, " <>
               "which is not among #{inspect(values)}"
    end
  end

  # WHAT THE AUTHOR IS OFFERED WHEN THEY AIM AT ONE. `Interactions.actions/1` filters the verb list
  # by what the target declared; a component declaring open and close must not be offered a toggle,
  # because `source/5` refuses one rather than falling through to the plain `JS.toggle` — which on a
  # dialog reveals the backdrop and leaves the panel hidden under it.
  test "the verbs offered are exactly the ones the component can honour", %{
    interactive: interactive
  } do
    for component <- interactive do
      opens = PaletteEntry.opens(component)

      offered =
        component
        |> then(&PaletteEntry.opens/1)
        |> Interactions.actions()
        |> Enum.map(&elem(&1, 0))

      for verb <- ~w(show hide toggle) do
        case Map.has_key?(opens, verb) do
          true ->
            assert verb in offered, "#{component["name"]} declares #{verb} and is not offered it"

          false ->
            refute verb in offered,
                   "#{component["name"]} is offered #{verb}, which it cannot honour"
        end
      end

      # The class actions are always there — they are the editor's, not the component's.
      assert "add_class" in offered
    end
  end

  # AND WHAT THAT COMPILES TO, for every declared verb of every interactive component. A verb that
  # compiles to `nil` is a control that silently does nothing when Apply is pressed.
  test "every declared verb compiles to a command aimed at the target", %{
    interactive: interactive
  } do
    for component <- interactive, {verb, attribute} <- PaletteEntry.opens(component) do
      source =
        Interactions.source(verb, "pb-deadbeef", %{
          target: "pb-target01",
          opener: %{verb => attribute}
        })

      assert source == ~s|JS.exec("#{attribute}", to: ".pb-target01")|,
             "#{component["name"]}'s #{verb} compiled to #{inspect(source)}"
    end
  end

  # THE DECLARATION HAS TO BE ON THE ROOT, because that is the only element `PaletteEntry.opens/1`
  # reads — one on a child is invisible to the editor and the author gets the generic verbs back.
  test "the declaration sits on the element the editor reads", %{interactive: interactive} do
    for component <- interactive do
      {:ok, tree} = Tree.parse(component["template"])
      root = tree |> Tree.children(:root) |> List.first()

      declared =
        for {_verb, attribute} <- PaletteEntry.opens(component),
            do: Node.attr(root, attribute)

      refute Enum.any?(declared, &is_nil/1),
             "#{component["name"]}'s declaration is not on its root element"
    end
  end

  # A COMPONENT SHOWN OPEN WHILE EDITING MUST HAVE SOMEWHERE TO DROP THINGS. All eleven take content;
  # the canvas draws the labelled empty well only for one that does.
  test "each one accepts content, which is what the canvas offers to fill", %{
    interactive: interactive
  } do
    for component <- interactive do
      slots = Enum.map(component["slots"] || [], & &1["name"])

      assert slots != [],
             "#{component["name"]} is shown open on the canvas but takes no content"
    end
  end

  # The values an attribute actually offers: the kit's own `values`, or what `features/1` derived
  # from the helper clauses when the attribute did not enumerate them itself. Read through the same
  # two sources the Inspector reads, so the test cannot disagree with the panel.
  defp enumerated(attribute, features) do
    case Map.get(features, Inspector.name(attribute)) do
      values when is_list(values) -> values
      _none -> Inspector.opts(attribute)["values"] |> List.wrap()
    end
  end

  # WHAT THE SWEEP TURNED UP. `chelekom-popover` declares `space` with `default: ""` and derives its
  # five values from its helper clauses. An empty string is truthy in Elixir, so the select's first
  # option interpolated it and read " (default)" — a blank label with a stray space, on the
  # component the question "how do I set this up" was asked about.
  test "a blank default is shown as the default, not as a blank label", %{
    interactive: interactive
  } do
    blank =
      for component <- interactive,
          attribute <- Inspector.attrs(component),
          Inspector.default(attribute) == "",
          do: {component["name"], Inspector.name(attribute)}

    refute blank == [], "the fixture has to contain a blank default for this to mean anything"

    assert Panels.default_text("") == nil
    assert Panels.default_text("   ") == nil
    assert Panels.default_text("medium") == "medium"
  end

  # THE SECOND THING THE SWEEP TURNED UP. `chelekom-dropdown` declares `position` with
  # `default: "bottom"` and no `values`, so the list is derived from clause heads — and the only
  # helper taking `@position` in a literal position is `dropdown_mobile_position`, whose two clauses
  # are "left" and "right". The panel offered a dropdown that could go left or right, on a component
  # whose default position is neither.
  test "a derived option list always contains the component's own default", %{
    components: components
  } do
    dropdown = Enum.find(components, &(&1["name"] == "chelekom-dropdown"))
    position = Enum.find(Inspector.attrs(dropdown), &(Inspector.name(&1) == "position"))

    assert Inspector.default(position) == "bottom"
    assert "bottom" in Map.fetch!(Inspector.features(dropdown), "position")
  end

  # And the rule generally, over everything the kit ships rather than the one that found it.
  test "no component anywhere offers a list its own default is missing from", %{
    components: components
  } do
    wrong =
      for component <- components,
          features = Inspector.features(component),
          attribute <- Inspector.attrs(component),
          values = Map.get(features, Inspector.name(attribute)),
          is_list(values) and values != [],
          default = Inspector.default(attribute),
          is_binary(default),
          String.trim(default) != "",
          default not in values,
          do: {component["name"], Inspector.name(attribute), default, values}

    assert wrong == [], "these defaults are not among their own options: #{inspect(wrong)}"
  end
end
