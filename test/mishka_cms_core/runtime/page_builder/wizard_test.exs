# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.WizardTest do
  @moduledoc """
  Composing a component from its own options — the other half of the examples modal.

  An example is a fixed point: the kit ships twelve alerts and none of them is a small outline alert
  in the warning colour. The wizard is how the author asks for that one directly, and what it emits
  has to be the same ordinary node an example insert produces.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Wizard

  defp attr(name, type \\ "string", opts \\ %{}),
    do: %{"name" => name, "type" => type, "opts" => opts}

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        name: "chelekom-alert",
        global?: false,
        attrs: [
          attr("variant", "string", %{"default" => "default"}),
          attr("kind", "atom", %{"default" => "natural"}),
          attr("title")
        ],
        slots: [%{"name" => "inner_block", "opts" => %{}, "attrs" => []}],
        helpers: [
          %{
            "name" => "color_variant",
            "discriminators" => [
              %{
                "axis" => "variant",
                "values" => ~w(default outline shadow bordered gradient base)
              },
              # `natural` is here because the real alert's colour axis contains its own attribute's
              # default — all thirteen of them. `pair_leftovers/3` reads exactly that to tell this
              # real `color` → `kind` from the generator axis it refuses on `divider`, so a fixture
              # that leaves the default out is testing a shape no kit ships.
              %{"axis" => "color", "values" => ~w(natural primary danger success warning)}
            ]
          }
        ],
        template: "<div class={color_variant(@variant, @kind)}>"
      },
      overrides
    )
  end

  # WHAT IS PREVIEWED IS NOT WHAT IS PLACED. `compose/3` seeded a component's required attributes the
  # `:preview` way for BOTH consumers — the iframe and the Insert button — so pressing Insert landed
  # `src="data:image/gif;base64,R0lGODlh…"`, the literal word "Example" and a fake flash map in the
  # document. Every one of those is non-empty, so `missing_required/1` passed them and publish
  # succeeded: visitors got a 1×1 transparent GIF. Dragging the same card off the palette lands
  # `src=""` and publish is correctly refused — the two doors disagreed.
  describe "the seeding style is the caller's" do
    defp needs_src do
      entry(%{
        name: "chelekom-image",
        attrs: [attr("src", "string", %{"required" => true})],
        slots: [],
        helpers: []
      })
    end

    test "an insert leaves a required attribute blank, so the save still refuses it" do
      source = Wizard.compose(needs_src(), %{}, "Global")

      assert source =~ ~s(src="")
      refute source =~ "data:image", "a preview placeholder was written into the document"
      refute source =~ "Example"
    end

    test "while a preview seeds it, or there is nothing to look at" do
      source = Wizard.compose(needs_src(), %{}, "Global", :preview)

      assert source =~ "data:image", "the preview has nothing to render"
    end

    test "and the default is the safe one" do
      assert Wizard.compose(needs_src(), %{}, "Global") ==
               Wizard.compose(needs_src(), %{}, "Global", :blank)
    end
  end

  describe "axes/1" do
    test "offers every attribute that has a real option list" do
      names = Enum.map(Wizard.axes(entry()), & &1.name)

      assert "variant" in names
      assert "kind" in names
    end

    test "a free-text attribute is the inspector's job, not the wizard's" do
      names = Enum.map(Wizard.axes(entry()), & &1.name)

      refute "title" in names
    end

    test "the colour axis reaches the attribute the template passes it to" do
      kind = Enum.find(Wizard.axes(entry()), &(&1.name == "kind"))

      assert kind.values == ~w(danger natural primary success warning)
      # …and it is an ATOM attribute, which is what decides how the value must be written.
      assert kind.atom?
    end

    # A BUNDLE IS A JSON FILE AN OPERATOR PASTED A URL FOR, so `values` and `default` can hold
    # anything. A map used to reach `to_string/1` and raise — survivable while `axes/1` ran only when
    # the wizard opened, fatal once `offers_options?/1` asks every palette entry whether it has any:
    # one such component crashed the whole palette load, and the builder came up with no components.
    test "a value with no string form is dropped rather than crashing the palette" do
      junk =
        entry(%{
          attrs: [
            %{
              "name" => "tone",
              "type" => "string",
              "opts" => %{"values" => ["calm", %{"x" => 1}, "loud"], "default" => %{"x" => 1}}
            }
          ],
          helpers: [],
          template: "<div class={paint(@tone)}>"
        })

      assert [tone] = Wizard.axes(junk)
      assert tone.values == ["calm", "loud"]
      assert tone.default == nil, "a default with no string form is no default"
    end

    test "a component whose only option list is junk offers no wizard" do
      junk =
        entry(%{
          attrs: [%{"name" => "tone", "type" => "string", "opts" => %{"values" => [%{"x" => 1}]}}],
          helpers: [],
          template: "<div class={paint(@tone)}>"
        })

      assert Wizard.axes(junk) == []
      refute Wizard.offers?(junk)
    end

    test "a component with no option lists offers no wizard at all" do
      plain = entry(%{attrs: [attr("name")], helpers: [], template: "<span class={@class}>"})

      assert Wizard.axes(plain) == []
      refute Wizard.offers?(plain)
    end

    # AN ASSIGN IS WHAT AN EXPRESSION READS, NOT A RUN OF CHARACTERS. This was a pattern over the
    # template and the helpers joined into one string, so `@tone` written out in a sentence the
    # component RENDERS — or inside a string it builds — counted as an assign the component reads,
    # and the wizard offered a picker that changes nothing on the page.
    test "an option only mentioned in the component's own words is not one it reads" do
      talkative =
        entry(%{
          attrs: [attr("tone", "string", %{"values" => ~w(calm loud)})],
          helpers: [],
          template: ~S|<div class="note">Set @tone to calm or loud.</div>|
        })

      assert Wizard.axes(talkative) == []
      refute Wizard.offers?(talkative)
    end

    test "and one a real expression reads still is" do
      reading =
        entry(%{
          attrs: [attr("tone", "string", %{"values" => ~w(calm loud)})],
          helpers: [],
          template: ~S|<div class={@tone}>Set @tone to calm or loud.</div>|
        })

      assert [tone] = Wizard.axes(reading)
      assert tone.name == "tone"
    end
  end

  describe "compose/3" do
    test "emits the same component invocation the palette does" do
      source = Wizard.compose(entry(), %{"variant" => "outline"}, "acme")

      assert source =~ ~s(component_name="chelekom-alert")
      assert source =~ ~s(site="acme")
      assert source =~ ~s(variant="outline")
    end

    test "what it emits is parseable, which is what makes it insertable" do
      source = Wizard.compose(entry(), %{"variant" => "outline", "kind" => "danger"}, "acme")

      assert {:ok, tree} = Tree.parse(source)
      assert [node] = Tree.walk(tree) |> Enum.filter(&(&1.kind == :component))
      assert MishkaCmsCore.Runtime.PageBuilder.Tree.Node.attr_text(node, "variant") == "outline"
    end

    # `kind="danger"` matches none of the component's clauses — they are written against the ATOM
    # `:danger` — so it falls through to whatever the catch-all renders and every colour comes out
    # identical. The kit's own examples write `kind={:primary}`; so does this.
    test "an atom attribute is written as an expression, not a string" do
      source = Wizard.compose(entry(), %{"kind" => "danger"}, "acme")

      assert source =~ "kind={:danger}"
      refute source =~ ~s(kind="danger")
    end

    test "a string attribute is still written as a string" do
      source = Wizard.compose(entry(), %{"variant" => "outline"}, "acme")

      assert source =~ ~s(variant="outline")
    end

    # Writing `variant="default"` says nothing the component does not already say, and every one is
    # another attribute the author reads past later.
    test "a value equal to the component's own default is left out" do
      source = Wizard.compose(entry(), %{"variant" => "default", "kind" => "danger"}, "acme")

      refute source =~ ~s(variant=)
      assert source =~ "kind={:danger}"
    end

    test "a value the attribute does not offer is refused, not written" do
      source = Wizard.compose(entry(), %{"kind" => "chartreuse"}, "acme")

      refute source =~ "chartreuse"
    end

    test "a blank choice is the same as not choosing" do
      assert Wizard.compose(entry(), %{"kind" => ""}, "acme") ==
               Wizard.compose(entry(), %{}, "acme")
    end

    # A global component is compiled under "Global" whatever page it lands on — the same rule the
    # palette and `Tree.rewrite_site/3` follow.
    test "a global component composes as Global whatever site it is placed on" do
      source = Wizard.compose(entry(%{global?: true}), %{}, "acme")

      assert source =~ ~s(site="Global")
    end

    # 293 of the kit's own examples are empty elements, which is most of why containers preview as a
    # blank rectangle.
    # The SAME starter the palette places, so what the wizard previews is what the insert produces.
    test "a component with an inner block gets something inside it to preview" do
      source = Wizard.compose(entry(), %{}, "acme")

      assert source =~ MishkaCmsCore.Runtime.PageBuilder.Starter.body(entry())
      refute source =~ "></.component>"
    end

    # SELF-CLOSING, not an empty open/close pair. Handing `<.component></.component>` to a component
    # that declares no `inner_block` — most form fields — makes Phoenix raise on a slot it never
    # declared, which answered the preview route with HTTP 500.
    test "a component with no inner block is composed self-closing" do
      no_block = entry(%{slots: []})
      source = Wizard.compose(no_block, %{}, "acme")

      assert source =~ "/>"
      refute source =~ "</.component>"
    end

    # Without this the wizard previews nothing but "chelekom-banner needs id — set it in the
    # inspector to render this", and since that placeholder is the same whatever else is chosen,
    # EVERY option in the panel looks broken: pick a colour, the frame refreshes, the same box
    # comes back.
    test "a required attribute is seeded, so there is a component to preview at all" do
      needy =
        entry(%{
          attrs: [
            attr("id", "string", %{"required" => true}),
            attr("variant", "string", %{"default" => "default"})
          ]
        })

      source = Wizard.compose(needy, %{}, "acme")

      assert source =~ ~s(id=")
      refute source =~ ~s(id="")
    end

    # An id that is empty is not a neutral placeholder: components build their own handlers as
    # `hide("##{@id}")`, and `"#"` matches nothing.
    test "a required id is minted rather than left blank" do
      needy = entry(%{attrs: [attr("id", "string", %{"required" => true})]})

      [_, id] = Regex.run(~r/id="([^"]*)"/, Wizard.compose(needy, %{}, "acme"))

      assert String.length(id) > 4
      refute id == Regex.run(~r/id="([^"]*)"/, Wizard.compose(needy, %{}, "acme")) |> Enum.at(1)
    end

    # The reader's own choice wins over the seed — otherwise the attribute would be written twice.
    test "a chosen value is not also seeded" do
      needy =
        entry(%{
          attrs: [attr("kind", "string", %{"required" => true, "values" => ~w(info danger)})]
        })

      source = Wizard.compose(needy, %{"kind" => "danger"}, "acme")

      assert source =~ ~s(kind="danger")
      refute source =~ ~s(kind="info")
    end

    # A required SLOT is the same trap: Phoenix assigns nothing for an omitted one, so the
    # component raises before it can render.
    test "a required slot is seeded too" do
      needy =
        entry(%{
          slots: [%{"name" => "manifest", "opts" => %{"required" => true}, "attrs" => []}]
        })

      assert Wizard.compose(needy, %{}, "acme") =~ "<:manifest></:manifest>"
    end

    # A slot `Starter` has sample copy for is furnished rather than left empty — being required only
    # decides that it must be written, not that it must be written blank.
    test "a slot the starter knows is furnished, not left empty" do
      needy =
        entry(%{
          slots: [%{"name" => "trigger", "opts" => %{"required" => true}, "attrs" => []}]
        })

      assert Wizard.compose(needy, %{}, "acme") =~ "<:trigger>Open</:trigger>"
    end
  end
end
