# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.InterfaceTest do
  @moduledoc """
  A component's declaration, checked the way the editor checks it.

  The rules are Phoenix's and the compiler's, not this editor's — a name becomes an atom and is
  written into a `def`, a required attribute may not also carry a default, `site` and
  `component_name` are declared for every runtime component whether the author asked or not. Nothing
  here knows a component name or a kit.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Interface

  defp attr(name, extra \\ %{}), do: Map.merge(%{"name" => name, "type" => "string"}, extra)
  defp slot(name, extra \\ %{}), do: Map.merge(%{"name" => name}, extra)

  describe "reading a record" do
    test "takes atom and string keys alike, and never returns nil" do
      assert Interface.attrs(%{attrs: [%{name: "size", type: "string"}]}) == [
               %{"name" => "size", "type" => "string"}
             ]

      assert Interface.slots(%{"slots" => [%{"name" => "item"}]}) == [%{"name" => "item"}]
      assert Interface.attrs(nil) == []
      assert Interface.slots(%{}) == []
    end
  end

  describe "validate/2" do
    test "passes a declaration with nothing wrong with it" do
      assert Interface.validate([attr("size")], [slot("inner_block")]) == []
    end

    # A name reaches the compiler as an atom and is written into a `def`, so anything that is not an
    # identifier is not a mistake worth discovering at compile time.
    test "refuses a name that cannot be one" do
      assert [{:attr, 0, message}] = Interface.validate([attr("Size")], [])
      assert message =~ "cannot be a name"

      assert [{:attr, 0, _dash}] = Interface.validate([attr("my-size")], [])
      assert [{:attr, 0, blank}] = Interface.validate([attr("")], [])
      assert blank =~ "Give this one a name"
    end

    test "and refuses the same name twice, on either list" do
      assert [{:attr, 1, message}] = Interface.validate([attr("size"), attr("size")], [])
      assert message =~ "declared twice"

      assert [{:slot, 1, _same}] = Interface.validate([], [slot("item"), slot("item")])
    end

    test "an attribute and a slot may share a name, because they are different things" do
      assert Interface.validate([attr("item")], [slot("item")]) == []
    end

    test "refuses a type nothing can declare" do
      assert [{:attr, 0, message}] = Interface.validate([attr("size", %{"type" => "colour"})], [])
      assert message =~ "not a type"
    end

    # Phoenix's own rule, and it raises at compile time rather than reporting: "attributes should not
    # have a default value if they are required".
    test "refuses required and a default together" do
      row = attr("size", %{"required" => "true", "default" => "medium"})

      assert [{:attr, 0, message}] = Interface.validate([row], [])
      assert message =~ "one or the other"
    end

    # THE SAME FACT, WRITTEN TWO WAYS. A row on its way out of the form carries `required` and
    # `default` at the top level; a row read back off the record carries both under `opts`, which is
    # where the compiler and `Inspector.default/1` look. Reading only one shape meant the rule was
    # checked for a form submission and not for anything already stored.
    test "and reads required and default off stored opts as well as a submitted form" do
      submitted = attr("size", %{"required" => "true", "default" => "medium"})
      stored = attr("size", %{"opts" => %{"required" => true, "default" => "medium"}})
      mixed = attr("size", %{"opts" => %{"required" => true}, "default" => "medium"})

      for row <- [submitted, stored, mixed] do
        assert [{:attr, 0, _refused}] = Interface.validate([row], [])
      end

      # And a default with nothing requiring it is perfectly ordinary.
      assert Interface.validate([attr("size", %{"opts" => %{"default" => "medium"}})], []) == []
    end

    # A SLOT'S OWN ATTRIBUTES ARE `attr :name, :type` INSIDE THE SLOT BLOCK, so every rule above is
    # as fatal there as at the top level. They went unchecked while the only way to write them was a
    # JSON textarea, which is exactly when a typo was most likely.
    test "and checks the attributes declared inside a slot by the same rules" do
      broken = slot("item", %{"attrs" => [attr("Label")]})

      assert [{:slot, 0, message}] = Interface.validate([], [broken])
      assert message =~ "attribute #1"
      assert message =~ "cannot be a name"
    end

    # NOT EVERY RULE, THOUGH. A slot's attribute never becomes an atom in a `def` — the compiler emits
    # slots without them — so an HTML name is a name there, as Phoenix allows in a slot block.
    # Chelekom's headless `toggle-group` declares `aria-label` on its `item`, and the whole kit failed
    # to install over it.
    test "a slot's attribute may be an HTML name, which a component's own may not" do
      for name <- ["aria-label", "data-state", "aria-labelled_by"] do
        assert Interface.validate([], [slot("item", %{"attrs" => [attr(name)]})]) == [], name
        assert [{:attr, 0, _identifier}] = Interface.validate([attr(name)], [])
      end

      for name <- ["aria-", "-label", "aria--label", "Aria-label"] do
        assert [{:slot, 0, message}] =
                 Interface.validate([], [slot("item", %{"attrs" => [attr(name)]})])

        assert message =~ "cannot be a name"
      end
    end

    test "reporting them against the slot that holds them, by position" do
      slot = slot("item", %{"attrs" => [attr("label"), attr("size", %{"type" => "colour"})]})

      assert [{:slot, 1, message}] = Interface.validate([], [slot("other"), slot])
      assert message =~ "attribute #2"
      assert message =~ "not a type"
    end

    test "a slot with attributes that are fine says nothing" do
      fine = slot("item", %{"attrs" => [attr("label"), attr("size")]})

      assert Interface.validate([], [fine]) == []
      assert Interface.validate([], [slot("item", %{"attrs" => []})]) == []
      assert Interface.validate([], [slot("item", %{"attrs" => nil})]) == []
    end

    # A SHORTER LIST THAN THE TOP LEVEL, and the compiler says why: `build_slots/1` emits a runtime
    # component's slots WITHOUT their nested attr declarations, so a slot attribute never reaches
    # `__attr__!` and Phoenix's rules for one — including the one that refuses `:default` inside a
    # slot outright — do not apply to it. What it is for here is the editor: `default` is what seeds
    # a required slot attribute when the slot is inserted, so required-with-a-default is the
    # feature rather than the fault.
    test "and a required slot attribute may carry the default that seeds it" do
      seeded =
        slot("item", %{
          "attrs" => [attr("kind", %{"opts" => %{"required" => true, "default" => "info"}})]
        })

      assert Interface.validate([], [seeded]) == []

      # While the same pair at the top level is still refused, because that one IS compiled.
      assert [{:attr, 0, _refused}] =
               Interface.validate(
                 [attr("kind", %{"opts" => %{"required" => true, "default" => "info"}})],
                 []
               )
    end

    # Two slots may each declare a `label`, because each is its own block.
    test "and two slots may declare the same attribute name" do
      one = slot("header", %{"attrs" => [attr("label")]})
      two = slot("footer", %{"attrs" => [attr("label")]})

      assert Interface.validate([], [one, two]) == []
    end

    # Phoenix's own refusal, and the plausible wrong turn: `inner_block` is the slot name everybody
    # knows, so declaring it as an attribute is the mistake worth naming rather than discovering at
    # compile time.
    test "refuses an attribute called inner_block, which is a slot" do
      assert [{:attr, 0, message}] = Interface.validate([attr("inner_block")], [])
      assert message =~ "is a slot, not an attribute"

      # And the slot of that name is perfectly ordinary.
      assert Interface.validate([], [slot("inner_block")]) == []
    end

    test "a struct attribute has to say which struct" do
      assert [{:attr, 0, message}] =
               Interface.validate([attr("field", %{"type" => "struct"})], [])

      assert message =~ "module it holds"

      named = attr("field", %{"type" => "struct", "struct_name" => "Phoenix.HTML.FormField"})
      assert Interface.validate([named], []) == []
    end
  end

  # THE OTHER DIRECTION, and the one that catches a KeyError before it happens: a template that reads
  # `@size` with no `attr :size` compiles and then raises the first time the component renders.
  describe "undeclared/3" do
    test "finds an assign the declaration never mentions" do
      found = Interface.undeclared(~s|<div class={@size}>{@title}</div>|, [attr("size")], [])

      assert found.attrs == ["title"]
      assert found.slots == []
    end

    test "finds a slot the same way" do
      found = Interface.undeclared(~s|<div>{render_slot(@inner_block)}</div>|, [], [])

      assert found.slots == ["inner_block"]
      assert found.attrs == [], "a slot is not a missing attribute"
    end

    test "and the comprehension form Phoenix writes for a multi-slot" do
      template = ~s|<li :for={{item, i} <- Enum.with_index(@item, 1)}>{render_slot(item)}</li>|
      found = Interface.undeclared(template, [], [])

      assert found.slots == ["item"]
      assert found.attrs == []
    end

    # A slot read only for its attributes is still a slot, and declaring it as one is still the fix —
    # but it must not be reported twice, once as each kind.
    test "a slot read only for its attributes is reported once, as a slot" do
      template = ~s|<source :for={s <- @source} src={s.src} />|
      found = Interface.undeclared(template, [], [])

      assert found.slots == []
      assert found.attrs == ["source"], "nothing renders it, so it reads as an attribute here"
    end

    test "says nothing about what is already declared" do
      template = ~s|<div class={@size}>{render_slot(@inner_block)}</div>|
      found = Interface.undeclared(template, [attr("size")], [slot("inner_block")])

      assert found == %{attrs: [], slots: []}
    end

    # The compiler declares both on every runtime component, so neither is ever the author's to add.
    test "never reports the two the compiler always provides" do
      template = ~s|<.component component_name={@component_name} site={@site} />|

      assert Interface.undeclared(template, [], []) == %{attrs: [], slots: []}
    end

    test "and reads a record with nothing in it without falling over" do
      assert Interface.undeclared(nil, [], []) == %{attrs: [], slots: []}
      assert Interface.undeclared("", [], []) == %{attrs: [], slots: []}
    end
  end

  describe "types/0" do
    test "is the vocabulary the Components form already offers" do
      assert "string" in Interface.types()
      assert "global" in Interface.types()
      assert "struct" in Interface.types()
      refute "colour" in Interface.types()
    end
  end
end
