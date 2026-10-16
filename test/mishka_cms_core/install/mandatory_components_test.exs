# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.MandatoryComponentsTest do
  @moduledoc """
  A kit declaring that the CMS cannot run without one of its components, and the installer honouring
  it.

  `dependencies` already answered "this component needs that one". Nothing answered "this install
  needs it at all" — `ui_kit_catalog.ex` said so in its own moduledoc: *the bundle JSON has no
  "required" flag*. So the picker would happily let an operator deselect `chelekom-icon`, which half
  the kit draws through, and the components that survived could not render.

  The flag seeds the dependency closure rather than being checked beside it, so it is locked in the
  UI and installed by the same path a dependency takes — one mechanism, not two.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Install.UiKitCatalog

  defp component(name, opts \\ []) do
    %{
      "name" => name,
      "type" => Keyword.get(opts, :type, "general"),
      "template" => "<div>#{name}</div>",
      "dependencies" => Keyword.get(opts, :deps, []),
      "required" => Keyword.get(opts, :required, false)
    }
  end

  defp catalog(components) do
    UiKitCatalog.build(%{
      "$schema" => "mishka.ui_kit.bundle.v3",
      "name" => "acme",
      "components" => components
    })
  end

  describe "a kit whose axes are not Chelekom's" do
    defp axis_component(name, axis, values, default) do
      %{
        "name" => name,
        "type" => "general",
        "template" => "<div class={paint(@#{axis})}>#{name}</div>",
        "attrs" => [
          %{
            "name" => axis,
            "type" => "string",
            "opts" => %{"values" => values, "default" => default}
          }
        ],
        "helpers" =>
          Enum.map(values, fn value ->
            %{
              "name" => "paint",
              "args" => ~s|"#{value}"|,
              "code" => ~s|defp paint("#{value}"), do: "x"|
            }
          end)
      }
    end

    # ELIGIBILITY IS STRUCTURAL NOW. Seven hardcoded names — Chelekom's most frequent — used to
    # decide which rows got an options panel, so a kit whose knobs are `tone`/`density` showed
    # checkbox and name only: no sliders icon, no error, no explanation. It then installed
    # UNNARROWED, the opposite of what the list was for.
    test "an unknown axis name is offered" do
      catalog = catalog([axis_component("acme-chip", "tone", ["calm", "loud"], "calm")])

      assert %{"tone" => %{values: ["calm", "loud"], default: "calm"}} =
               catalog.index["acme-chip"].config
    end

    test "a known axis name still works" do
      catalog = catalog([axis_component("acme-btn", "variant", ["solid", "soft"], "solid")])

      assert Map.has_key?(catalog.index["acme-btn"].config, "variant")
    end

    # The seven names survive as a SORT KEY, which is all the order was ever for.
    test "known axes sort before unknown ones" do
      sorted =
        UiKitCatalog.sort_axes(%{
          "zebra" => %{},
          "color" => %{},
          "variant" => %{},
          "alpha" => %{}
        })

      assert Enum.map(sorted, &elem(&1, 0)) == ["variant", "color", "alpha", "zebra"]
    end

    # NARROWING FOLLOWS THE PICKER. An axis that is offered is narrowed to its default, chosen for or
    # not — that is what the installer is for, and it is what the operator sees preselected. Opening
    # the eligible set widens what gets narrowed too, which is only safe because an axis needs a real
    # string default before it becomes eligible at all.
    test "an axis the operator did not touch is narrowed to its default" do
      catalog = catalog([axis_component("acme-chip", "tone", ["calm", "loud"], "calm")])
      selection = UiKitCatalog.install_selection_by_kit(catalog, ["acme-chip"], %{})

      assert selection["acme"].per_component["chip"] == %{"tone" => ["calm"]}
    end

    # An attribute with option values but NO default is not offered and not narrowed — narrowing it
    # would mean choosing a default nobody wrote, and a component whose helper loses every matching
    # clause does not compile.
    test "an axis with no default is neither offered nor narrowed" do
      component = axis_component("acme-chip", "tone", ["calm", "loud"], nil)
      component = put_in(component, ["attrs", Access.at(0), "opts", "default"], nil)
      catalog = catalog([component])

      refute Map.has_key?(catalog.index["acme-chip"].config, "tone")

      selection = UiKitCatalog.install_selection_by_kit(catalog, ["acme-chip"], %{})
      assert selection["acme"].per_component["chip"] == %{}
    end

    test "an axis the operator did choose for is narrowed to default plus their picks" do
      catalog = catalog([axis_component("acme-chip", "tone", ["calm", "loud"], "calm")])

      selection =
        UiKitCatalog.install_selection_by_kit(
          catalog,
          ["acme-chip"],
          %{"acme-chip" => %{"tone" => MapSet.new(["loud"])}}
        )

      assert %{"tone" => picks} = selection["acme"].per_component["chip"]
      assert Enum.sort(picks) == ["calm", "loud"]
    end
  end

  describe "a kit's own mandatory set" do
    test "a component marked required is mandatory even when nothing was picked" do
      catalog = catalog([component("acme-icon", required: true), component("acme-card")])

      assert UiKitCatalog.mandatory(catalog) == MapSet.new(["acme-icon"])
      assert MapSet.member?(UiKitCatalog.install_set(catalog, []), "acme-icon")
    end

    test "a kit that declares none has no mandatory set" do
      catalog = catalog([component("acme-card"), component("acme-button")])

      assert UiKitCatalog.mandatory(catalog) == MapSet.new()
      assert UiKitCatalog.install_set(catalog, []) == MapSet.new()
    end

    # THE POINT. `required_closure/2` is what the picker locks, so seeding the mandatory set into it
    # is what makes the checkbox uncheckable — rather than a second rule the UI has to remember.
    test "a required component is locked in the picker, not merely installed" do
      catalog = catalog([component("acme-icon", required: true), component("acme-card")])

      assert MapSet.member?(UiKitCatalog.required_closure(catalog, ["acme-card"]), "acme-icon")
    end

    # Deselecting everything is a real thing an operator does, and it must not produce an install
    # that cannot render.
    test "clearing the whole picker still installs what the kit requires" do
      catalog =
        catalog([
          component("acme-icon", required: true),
          component("acme-card"),
          component("acme-button")
        ])

      assert UiKitCatalog.install_set(catalog, []) == MapSet.new(["acme-icon"])
    end

    test "required and dependencies compose" do
      catalog =
        catalog([
          component("acme-icon", required: true),
          component("acme-error"),
          component("acme-field", deps: ["acme-error"])
        ])

      installed = UiKitCatalog.install_set(catalog, ["acme-field"])

      assert MapSet.equal?(installed, MapSet.new(["acme-field", "acme-error", "acme-icon"]))
    end

    # `required` is optional, and a bundle written before it existed must keep installing.
    test "a bundle with no required key at all is unaffected" do
      catalog =
        UiKitCatalog.build(%{
          "$schema" => "mishka.ui_kit.bundle.v3",
          "name" => "legacy",
          "components" => [%{"name" => "legacy-card", "template" => "<div/>"}]
        })

      assert UiKitCatalog.mandatory(catalog) == MapSet.new()
    end
  end
end
