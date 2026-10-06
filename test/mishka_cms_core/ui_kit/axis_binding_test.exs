defmodule MishkaCmsCore.UiKit.AxisBindingTest do
  @moduledoc """
  Which attribute a helper's option list actually belongs to.

  A discriminator is keyed by the helper's own PARAMETER name, and the attribute passed in is a
  different thing: alert's template calls `color_variant(@variant, @kind)`, so the thirteen colours
  belong to `kind`. Without the binding they belonged to an attribute the component does not have,
  and the single most consequential choice on an alert — primary, danger? — had no picker at all.

  The guard is the other half. One spare axis and one spare attribute is not evidence that they
  belong together, and the shipped kit contains two pairs that plainly do not.

  Asserted against the REAL bundle as well as against fixtures, because the value of both rules is
  measured in what they do to Chelekom.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  @bundle MishkaCmsCore.Runtime.Handlers.UiKitHandler.default_bundle_path()

  setup_all do
    {:ok, bundle: @bundle |> File.read!() |> Jason.decode!()}
  end

  defp component(bundle, name), do: Enum.find(bundle["components"], &(&1["name"] == name))

  defp rebinds(bundle) do
    for c <- bundle["components"],
        {axis, attr} <- UiKitHandler.axis_bindings(c),
        axis != attr,
        do: {c["name"], axis, attr}
  end

  describe "the binding itself" do
    test "an axis named after a passed attribute binds to it", %{bundle: b} do
      bindings = UiKitHandler.axis_bindings(component(b, "chelekom-alert"))

      assert bindings["variant"] == "variant"
    end

    # THE CASE THE WHOLE MECHANISM EXISTS FOR. `color_variant(@variant, @kind)` — the axis is called
    # `color` and the attribute is called `kind`.
    test "the leftover pair recovers alert's colours onto kind", %{bundle: b} do
      assert UiKitHandler.axis_bindings(component(b, "chelekom-alert"))["color"] == "kind"
      assert UiKitHandler.axis_bindings(component(b, "chelekom-flash"))["color"] == "kind"
    end
  end

  describe "the plausibility guard" do
    # `divider` and `hr` pass `@position` to a helper carrying the generator's `type` axis. The
    # attribute's own default is `middle`; the axis offers two values and `middle` is not one of
    # them. The panel drew a picker whose options could not include what the element already was.
    test "a pairing whose attribute default the axis has never heard of is refused", %{bundle: b} do
      for name <- ~w(chelekom-divider chelekom-hr) do
        component = component(b, name)

        assert get_in(component, ["attrs"]) |> Enum.find(&(&1["name"] == "position")),
               "#{name} is expected to declare `position` — the fixture has moved"

        refute UiKitHandler.axis_bindings(component)["type"] == "position",
               "#{name} bound its generator axis onto an attribute that cannot hold those values"
      end
    end

    test "a blank default proves nothing, so the pairing stands" do
      # No evidence either way, and a text box would be a worse answer than a list — so it binds.
      component = %{
        "template" => ~S|<div class={shade(@tone)}>x</div>|,
        "attrs" => [%{"name" => "tone", "opts" => %{"default" => ""}}],
        "helpers" => [
          %{"name" => "shade", "discriminators" => [%{"axis" => "hue", "values" => ["warm"]}]}
        ]
      }

      assert UiKitHandler.axis_bindings(component)["hue"] == "tone"
    end

    # AND AN AXIS WITH ITS OWN HOME IS NOT LOOKING FOR ONE. `chelekom-gallery` declares `type`
    # (default | masonry | featured) and its `column_class` clauses carry a `type` axis whose one
    # value is `gallery` — the generator naming which component the clause belongs to. Paired onto
    # the one spare attribute, that made `cols` a picker offering a single swatch reading "gallery"
    # where twelve column counts belong. A blank default proves nothing; a declared attribute of the
    # same name proves the axis is not about anything else.
    test "an axis named after an attribute the component declares is not paired elsewhere", %{
      bundle: b
    } do
      gallery = component(b, "chelekom-gallery")

      assert Enum.find(gallery["attrs"], &(&1["name"] == "type")),
             "chelekom-gallery is expected to declare `type` — the fixture has moved"

      refute UiKitHandler.axis_bindings(gallery)["type"] == "cols"
      refute UiKitHandler.component_features(gallery)["cols"]
      assert UiKitHandler.component_features(gallery)["type"] == ~w(default masonry featured)
    end

    # AND NOT ONTO ITSELF EITHER, unchecked. `chelekom-divider` declares `type` as
    # dashed/dotted/solid, and the generator's `type` axis reads `["hr", "divider"]`; keyed onto the
    # attribute of its own name it replaced three real values with two that are not values at all.
    test "an unbound axis keys onto its own name only if the default agrees", %{bundle: b} do
      for name <- ~w(chelekom-divider chelekom-hr) do
        assert UiKitHandler.component_features(component(b, name))["type"] ==
                 ~w(dashed dotted solid),
               "#{name} still shows the generator's own axis"
      end
    end

    # The guard must not be a quiet way of turning the feature off. Pinned as a count so a change
    # that refuses everything, or accepts everything again, fails here rather than in the panel.
    test "over the whole kit it refuses three pairings and keeps four", %{bundle: b} do
      kept = rebinds(b)

      assert length(kept) == 4, "kept: #{inspect(kept)}"
      assert {"chelekom-alert", "color", "kind"} in kept
    end
  end

  describe "what it will not guess" do
    test "two spare axes and two spare attributes bind to nothing" do
      component = %{
        "template" => ~S|<div class={two(@one, @two)}>x</div>|,
        "attrs" => [%{"name" => "one"}, %{"name" => "two"}],
        "helpers" => [
          %{
            "name" => "two",
            "discriminators" => [
              %{"axis" => "alpha", "values" => ["a"]},
              %{"axis" => "beta", "values" => ["b"]}
            ]
          }
        ]
      }

      assert UiKitHandler.axis_bindings(component) == %{}
    end

    test "a helper the template never calls contributes nothing" do
      component = %{
        "template" => ~S|<div>x</div>|,
        "attrs" => [%{"name" => "kind"}],
        "helpers" => [
          %{"name" => "colour", "discriminators" => [%{"axis" => "color", "values" => ["red"]}]}
        ]
      }

      assert UiKitHandler.axis_bindings(component) == %{}
    end

    # A CALL AROUND A CALL. The scan was `~r/\b([a-z_][a-z0-9_]*)\s*\(([^()]*)\)/`, and `[^()]*` is
    # the whole problem: a match's arguments cannot contain a bracket, so the inner call was the only
    # one found and the outer helper — the one carrying the axis — went unbound. Read off the parsed
    # expression, both are calls and nesting is not a special case.
    test "a helper called around another helper is still called" do
      component = %{
        "template" => ~S|<div class={colour(@kind, size(@scale))}>x</div>|,
        "attrs" => [%{"name" => "kind"}, %{"name" => "scale"}],
        "helpers" => [
          %{"name" => "colour", "discriminators" => [%{"axis" => "color", "values" => ["red"]}]},
          %{"name" => "size", "discriminators" => [%{"axis" => "scale", "values" => ["sm"]}]}
        ]
      }

      bindings = UiKitHandler.axis_bindings(component)

      assert bindings["color"] == "kind", "the outer helper's axis was lost to the nested call"
      assert bindings["scale"] == "scale"
    end

    # AND WHAT IS NOT AN EXPRESSION IS NOT A CALL. Parens in a class name, in a string the component
    # builds, or in prose it renders all read as calls to a pattern that keys on brackets.
    test "something shaped like a call in the text is not one" do
      component = %{
        "template" => ~S|<div class="note">Pass colour(@kind) to style it.</div>|,
        "attrs" => [%{"name" => "kind"}],
        "helpers" => [
          %{"name" => "colour", "discriminators" => [%{"axis" => "color", "values" => ["red"]}]}
        ]
      }

      assert UiKitHandler.axis_bindings(component) == %{}
    end
  end

  # EVERYTHING ABOVE IS INFERENCE, and inference is what a second kit can break. A kit that says
  # which attribute each axis describes is believed, and none of it runs. The exporter emitting the
  # key lives in the kit's own repository; this end is ready for it now, so the day a bundle ships
  # `axes` the guessing stops for that component with no change here.
  describe "a kit that declares its axes" do
    # Shaped so INFERENCE has an answer of its own — one spare axis, one spare attribute, so the
    # leftover rule pairs `color` with `kind`. Every test below that declares something else is
    # therefore proving the declaration wins, not merely that it agrees.
    defp declaring(axes) do
      %{
        "template" => ~S|<div class={colour(@kind)}>x</div>|,
        "attrs" => [%{"name" => "variant"}, %{"name" => "kind"}],
        "helpers" => [
          %{
            "name" => "colour",
            "discriminators" => [%{"axis" => "color", "values" => ["red"]}]
          }
        ],
        "axes" => axes
      }
    end

    test "is believed, and the template is not read at all" do
      component = declaring([%{"name" => "color", "attr" => "variant"}])

      assert UiKitHandler.axis_bindings(component) == %{"color" => "variant"},
             "inference would have paired color with kind"
    end

    test "several axes at once" do
      component =
        declaring([
          %{"name" => "color", "attr" => "kind"},
          %{"name" => "size", "attr" => "variant"}
        ])

      assert UiKitHandler.axis_bindings(component) == %{"color" => "kind", "size" => "variant"}
    end

    # `scope` names the helper an axis belongs to, which matters to the exporter and not to a map
    # from axis to attribute. Reading it would only give this end a second thing to disagree about.
    test "an extra key on an entry is ignored rather than refused" do
      component = declaring([%{"name" => "color", "attr" => "kind", "scope" => "colour"}])

      assert UiKitHandler.axis_bindings(component) == %{"color" => "kind"}
    end

    # A typo in somebody's bundle. Honouring it would draw a picker onto a property the component
    # does not have, which is the exact failure the inference guard exists to prevent.
    test "an entry naming an attribute the component does not declare is dropped" do
      component = declaring([%{"name" => "color", "attr" => "nonesuch"}])

      assert UiKitHandler.axis_bindings(component) == %{}
    end

    test "a malformed or blank entry is dropped, and the rest still bind" do
      component =
        declaring([
          %{"name" => "color", "attr" => "kind"},
          %{"name" => "  ", "attr" => "variant"},
          %{"name" => "size"},
          %{"attr" => "variant"},
          "not an object"
        ])

      assert UiKitHandler.axis_bindings(component) == %{"color" => "kind"}
    end

    # THE KEY IS THE OPT-OUT, NOT THE ENTRIES. Falling back on a typo would re-enable, quietly, the
    # exact mechanism the declaration was written to replace — and it could bind somewhere the kit
    # never meant. An empty list is a positive statement too: this component has no axes.
    test "declaring anything at all stops the guessing, even when nothing survives" do
      assert UiKitHandler.axis_bindings(declaring([])) == %{}
      assert UiKitHandler.axis_bindings(declaring([%{"name" => "color"}])) == %{}
    end

    # The fallback has to stay reachable, because a bundle with no `axes` key is the bundle that
    # ships today.
    test "a component that declares nothing is still read from its template" do
      assert UiKitHandler.axis_bindings(declaring(nil)) == %{"color" => "kind"}

      assert UiKitHandler.axis_bindings(Map.delete(declaring(nil), "axes")) == %{
               "color" => "kind"
             }
    end

    test "the shipped kit declares none yet, so nothing about it changes", %{bundle: b} do
      refute Enum.any?(b["components"], &is_list(&1["axes"]))
      assert length(rebinds(b)) == 4
    end
  end
end
