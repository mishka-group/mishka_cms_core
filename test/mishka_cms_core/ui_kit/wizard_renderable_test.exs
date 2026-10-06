defmodule MishkaCmsCore.UiKit.WizardRenderableTest do
  @moduledoc """
  Tier 3 — every component of every installed kit must be PREVIEWABLE by the palette's wizard.

  The bug this exists for: `chelekom-banner` declares `id` as required with no default, the wizard
  composed `<.component component_name="chelekom-banner" …>` without one, and the canvas answered
  with "chelekom-banner needs id — set it in the inspector to render this". Because that placeholder
  is the same whatever else is chosen, EVERY option in the panel looked dead — pick a colour, the
  frame refreshes, the same box comes back. Twenty-two of the kit's components were in that state.

  It reads the bundle JSON rather than the database on purpose. That is the shipped contract, it
  needs no Postgres, and it covers **whatever kits are installed**: drop another package's bundle
  into `priv/cms_ui_kits/` and its components are held to the same rule without a line changing
  here.

  See `MishkaCmsCore.Builder.PaletteEntry.seeded/2`, which is the single answer to "what does this
  component need in order to render at all", and `MishkaCmsCore.Runtime.PageBuilder.Wizard.compose/3`,
  which asks it.
  """

  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Wizard

  @moduletag :unit

  @kits_dir MishkaCmsCore.Runtime.Handlers.UiKitHandler.kits_dir()

  setup_all do
    components =
      @kits_dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> Jason.decode!()
        |> Map.get("components", [])
        |> Enum.map(&{Path.basename(path), &1})
      end)

    {:ok, components: components}
  end

  # An attribute the component's own template reads and nothing supplies. Reading a missing assign
  # raises `KeyError`, which is why this is fatal rather than cosmetic.
  defp required_without_default(component) do
    component
    |> Map.get("attrs", [])
    |> Enum.filter(fn attr ->
      opts = Map.get(attr, "opts") || %{}

      Map.get(opts, "required") in [true, "true"] and is_nil(Map.get(opts, "default")) and
        Map.get(attr, "type") not in ["global", "struct"]
    end)
    |> Enum.map(&Map.get(&1, "name"))
  end

  defp required_slots(component) do
    component
    |> Map.get("slots", [])
    |> Enum.filter(fn slot ->
      opts = Map.get(slot, "opts") || %{}
      Map.get(opts, "required") in [true, "true"] and Map.get(slot, "name") != "inner_block"
    end)
    |> Enum.map(&Map.get(&1, "name"))
  end

  # Every assign the component can read: its own template plus each helper body.
  defp assign_reads(component) do
    helpers =
      component
      |> Map.get("helpers", [])
      |> Enum.map_join("\n", &to_string(Map.get(&1, "code") || ""))

    ~r/@([a-zA-Z_][a-zA-Z_0-9]*)/
    |> Regex.scan("#{Map.get(component, "template", "")}\n#{helpers}")
    |> MapSet.new(&Enum.at(&1, 1))
  end

  defp entry(component) do
    %{
      name: Map.get(component, "name"),
      global?: true,
      attrs: Map.get(component, "attrs", []),
      slots: Map.get(component, "slots", []),
      helpers: Map.get(component, "helpers", []),
      template: Map.get(component, "template", "")
    }
  end

  describe "every kit component the wizard can offer" do
    test "the bundles are actually there to check", %{components: components} do
      assert length(components) >= 100,
             "expected the installed kits to ship components; found #{length(components)}"
    end

    test "composes with every required attribute supplied", %{components: components} do
      missing =
        for {kit, component} <- components,
            source = Wizard.compose(entry(component), %{}, nil),
            name <- required_without_default(component),
            not String.contains?(source, "#{name}="),
            do: "#{kit}: #{Map.get(component, "name")} is missing #{name}"

      assert missing == [],
             "these components would preview as \"needs …\" instead of themselves:\n" <>
               Enum.join(missing, "\n")
    end

    # The pair that answered HTTP 500. A form field builds `<input name={@name} value={@value}>`;
    # declared without defaults and never passed, both are nil and the field renders as nothing —
    # `chelekom-tel-field` did exactly that. Only these two are seeded: Phoenix sets nil for any
    # declared attribute with no default, so `@class` on a component that never receives one is
    # harmless, and seeding every such attribute put the word "Example" inside components that were
    # rendering perfectly well.
    #
    # `Map.has_key?`, NOT `is_nil(Map.get(...))`. This test asked the second question and so did
    # `PaletteEntry.seed?/3`, and neither can tell an attribute that declares NO default from one
    # that declares `default: nil` — 584 of the kit's attributes are the second kind. Phoenix merges
    # a declared default in whatever its value, so `@value` on `chelekom-progress` and
    # `chelekom-stat` is `nil` and always was; nothing supplies it because nothing has to. The
    # question that matters is the one the production rule now asks.
    test "a form field's name and value are supplied, or it renders as nothing", %{
      components: components
    } do
      missing =
        for {kit, component} <- components,
            source = Wizard.compose(entry(component), %{}, nil),
            reads = assign_reads(component),
            attr <- Map.get(component, "attrs", []),
            name = Map.get(attr, "name"),
            name in ~w(name value),
            opts = Map.get(attr, "opts") || %{},
            not Map.has_key?(opts, "default"),
            Map.get(attr, "type") not in ["global", "struct"],
            MapSet.member?(reads, name),
            not String.contains?(source, "#{name}="),
            do: "#{kit}: #{Map.get(component, "name")} reads @#{name} and nothing supplies it"

      assert missing == [],
             "these render as an empty field:\n" <> Enum.join(missing, "\n")
    end

    test "composes with every required slot supplied", %{components: components} do
      missing =
        for {kit, component} <- components,
            source = Wizard.compose(entry(component), %{}, nil),
            name <- required_slots(component),
            not String.contains?(source, "<:#{name}"),
            do: "#{kit}: #{Map.get(component, "name")} is missing slot #{name}"

      assert missing == [],
             "a required slot Phoenix assigns nothing for raises before the component renders:\n" <>
               Enum.join(missing, "\n")
    end

    # A seeded `id` of `""` is not a neutral placeholder: components build their own handlers as
    # `hide("##{@id}")`, and `"#"` matches nothing — the control renders and does nothing.
    test "a required id is minted rather than left blank", %{components: components} do
      blank =
        for {kit, component} <- components,
            "id" in required_without_default(component),
            source = Wizard.compose(entry(component), %{}, nil),
            String.contains?(source, ~s(id="")),
            do: "#{kit}: #{Map.get(component, "name")}"

      assert blank == [], "these compose an empty id:\n" <> Enum.join(blank, "\n")
    end

    test "what it composes is markup the editor can parse", %{components: components} do
      unparseable =
        for {kit, component} <- components,
            source = Wizard.compose(entry(component), %{}, nil),
            match?({:error, _reason}, Tree.parse(source)),
            do: "#{kit}: #{Map.get(component, "name")} — #{source}"

      assert unparseable == [],
             "the wizard emits what an insert would place, so it has to parse:\n" <>
               Enum.join(unparseable, "\n")
    end

    # Every option the panel offers has to reach the markup, or the reader changes it and nothing
    # happens. This is the wizard's own contract; whether the KIT then honours the value is the
    # component's business.
    test "every offered option writes a distinct component", %{components: components} do
      inert =
        for {kit, component} <- components,
            entry = entry(component),
            axis <- Wizard.axes(entry),
            length(axis.values) > 1,
            sources = Enum.map(axis.values, &Wizard.compose(entry, %{axis.name => &1}, nil)),
            length(Enum.uniq(sources)) <= 1,
            do: "#{kit}: #{Map.get(component, "name")}.#{axis.name}"

      assert inert == [],
             "these offer options that compose the same markup whatever is picked:\n" <>
               Enum.join(inert, "\n")
    end
  end

  # A kit is installed a variant at a time — "base only", "just two paddings" — and the exporter then
  # emits only the clauses that were chosen. The wizard must offer what THIS install shipped, not what
  # the component could have shipped, or the author picks `variant="shadow"`, the preview does not
  # change, and the option looks broken rather than absent.
  defp helper(name, args, discriminators) do
    %{"name" => name, "args" => args, "code" => "[\"px-2\"]", "discriminators" => discriminators}
  end

  defp axis(entry, name), do: Enum.find(Wizard.axes(entry), &(&1.name == name))

  defp component(helpers) do
    %{
      name: "acme-widget",
      global?: true,
      template: "<div class={padding_size(@padding)}>{render_slot(@inner_block)}</div>",
      attrs: [
        %{
          "name" => "padding",
          "type" => "string",
          "opts" => %{"values" => ~w(extra_small small medium large extra_large)}
        }
      ],
      slots: [%{"name" => "inner_block", "opts" => %{}}],
      helpers: helpers
    }
  end

  describe "an install that shipped only some of a component's variants" do
    test "offers only the values whose clauses were installed" do
      entry =
        component([
          helper("padding_size", ~s("extra_small"), []),
          helper("padding_size", ~s("small"), [])
        ])

      assert axis(entry, "padding").values == ~w(extra_small small)
    end

    # The recorded discriminators stay the authority — the clause heads are only consulted where the
    # extractor left none.
    test "a recorded discriminator wins over the clause heads" do
      entry =
        component([
          helper("padding_size", ~s("extra_small"), [
            %{"axis" => "padding", "values" => ~w(medium large)}
          ])
        ])

      assert axis(entry, "padding").values == ~w(large medium)
    end

    # The user's point, and the thing that makes hiding the wrong instrument: a helper with a
    # catch-all accepts every value, so every declared value renders. `chelekom-banner` reaches
    # `rounded_size`'s fallback for `rounded_position="none"` and that IS what none means. 25 of the
    # kit's 364 option lists are backed this way — hiding them would have taken working controls off
    # `chelekom-accordion`, `chelekom-combobox` and `chelekom-pagination` with them.
    test "a catch-all clause means every declared value stands" do
      entry =
        component([
          helper("padding_size", ~s("small"), []),
          helper("padding_size", "params", [])
        ])

      assert axis(entry, "padding").values == ~w(extra_small small medium large extra_large)
    end

    # An attribute that reaches the DOM directly — `<input type={@type}>`, `<img loading={@loading}>`
    # — has no clauses to count and needs none. These are HTML's own values, present in every install.
    test "a native HTML attribute keeps its declared values", %{components: components} do
      {_kit, button} = Enum.find(components, fn {_kit, c} -> c["name"] == "chelekom-button" end)

      entry = %{
        name: button["name"],
        global?: true,
        template: button["template"],
        attrs: button["attrs"],
        slots: button["slots"],
        helpers: button["helpers"]
      }

      assert %{values: values} = axis(entry, "type")
      assert "submit" in values and "button" in values
    end
  end
end
