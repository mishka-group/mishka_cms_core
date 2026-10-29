# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.InspectorTest do
  @moduledoc """
  The property panel's brain: which control an attribute gets, and where its option list comes from.

  The option-list case is the important one. A Chelekom attribute is almost always declared as a
  bare `"string"`; the real values live in the component's `helpers[].discriminators`, a field the
  old editor payload never carried. Folding it in is what turns 1,764 text boxes into real controls.

  The two form sections answer a different question — what a node needs in order to be a working form
  — so nothing about them is derived from a kit's attribute list. What is pinned here is that they
  apply to the right nodes, that a rename is ONE batch touching all five derived names, and that a
  seed another form already holds is refused before it is written.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Builder.Descriptor
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.Authoring.Inspector
  alias MishkaCmsCore.Runtime.Authoring.PageForms
  alias MishkaCmsCore.Runtime.Authoring.PageForms.Naming
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Test.Factory

  # The real Chelekom rows the form pill reads.
  setup_all do
    {:ok,
     chelekom:
       Factory.chelekom_rows(
         ~w(chelekom-button chelekom-card chelekom-text-field chelekom-form-wrapper chelekom-simple-form)
       )}
  end

  defp attr(name, type \\ "string", opts \\ %{}),
    do: %{"name" => name, "type" => type, "opts" => opts}

  defp component(attrs, helpers \\ []), do: %{"attrs" => attrs, "helpers" => helpers}

  defp discriminator(axis, values), do: %{"axis" => axis, "values" => values}

  describe "features/1 — where the option lists come from" do
    test "folds helper discriminators into a per-attribute value list" do
      comp =
        component(
          [attr("color"), attr("size")],
          [
            %{
              "discriminators" => [
                discriminator("color", ~w(primary danger)),
                discriminator("size", ~w(sm lg))
              ]
            }
          ]
        )

      assert Inspector.features(comp) == %{"color" => ~w(danger primary), "size" => ~w(lg sm)}
    end

    test "unions the axes declared across several helpers" do
      comp =
        component(
          [attr("color")],
          [
            %{"discriminators" => [discriminator("color", ~w(primary))]},
            %{"discriminators" => [discriminator("color", ~w(danger))]}
          ]
        )

      assert Inspector.features(comp)["color"] == ~w(danger primary)
    end

    test "an attribute's own opts.values are used when no helper covers it" do
      comp = component([attr("tone", "string", %{"values" => ~w(soft loud)})])

      assert Inspector.features(comp)["tone"] == ~w(soft loud)
    end

    test "helper values win over attr-declared ones" do
      comp =
        component(
          [attr("color", "string", %{"values" => ~w(stale)})],
          [%{"discriminators" => [discriminator("color", ~w(fresh))]}]
        )

      assert Inspector.features(comp)["color"] == ~w(fresh)
    end

    test "a component with neither yields no features rather than failing" do
      assert Inspector.features(component([attr("label")])) == %{}
      assert Inspector.features(%{}) == %{}
    end

    test "reads helpers held as embedded structs, not only as maps" do
      helper = %MishkaCmsCore.Runtime.Resources.Embeddeds.Helper{
        name: "color_class",
        code: "def x, do: 1",
        discriminators: [discriminator("color", ~w(primary))]
      }

      assert Inspector.features(%{attrs: [], helpers: [helper]})["color"] == ~w(primary)
    end
  end

  describe "axis bindings — whose option list is it" do
    # A discriminator is keyed by the helper's own PARAMETER name. Alert's template calls
    # `color_variant(@variant, @kind)`, so the eleven colours belong to `kind` — keyed by "color"
    # they belonged to an attribute alert does not have, and its most consequential choice had no
    # picker at all.
    test "an axis binds to the attribute the template passes in that position" do
      comp = %{
        "attrs" => [attr("variant"), attr("kind", "atom")],
        "template" => "<div class={color_variant(@variant, @kind)}>",
        "helpers" => [
          %{
            "name" => "color_variant",
            "discriminators" => [
              discriminator("variant", ~w(default outline)),
              discriminator("color", ~w(primary danger))
            ]
          }
        ]
      }

      assert Inspector.features(comp) == %{
               "variant" => ~w(default outline),
               "kind" => ~w(danger primary)
             }
    end

    test "an axis named after its attribute binds to it directly" do
      comp = %{
        "attrs" => [attr("color")],
        "template" => "<div class={color_class(@color)}>",
        "helpers" => [
          %{"name" => "color_class", "discriminators" => [discriminator("color", ~w(red blue))]}
        ]
      }

      assert Inspector.features(comp) == %{"color" => ~w(blue red)}
    end

    # Two spare axes and two spare attributes could pair either way, and guessing would put the
    # colours on the padding.
    test "an ambiguous call is left alone rather than guessed" do
      comp = %{
        "attrs" => [attr("tone"), attr("scale")],
        "template" => "<div class={both(@tone, @scale)}>",
        "helpers" => [
          %{
            "name" => "both",
            "discriminators" => [
              discriminator("color", ~w(red)),
              discriminator("size", ~w(sm))
            ]
          }
        ]
      }

      assert Inspector.features(comp) == %{"color" => ~w(red), "size" => ~w(sm)}
    end

    # `chelekom-card-title` ships `color_variant` because it shares a source file with `card`, but
    # declares no colour attribute and never calls it. There is nothing to bind, and inventing a
    # binding would put a colour picker on its padding.
    test "a helper the template never calls binds to nothing" do
      comp = %{
        "attrs" => [attr("padding")],
        "template" => "<div class={padding_size(@padding)}>",
        "helpers" => [
          %{"name" => "padding_size", "discriminators" => [discriminator("padding", ~w(sm lg))]},
          %{"name" => "color_variant", "discriminators" => [discriminator("color", ~w(primary))]}
        ]
      }

      features = Inspector.features(comp)

      assert features["padding"] == ~w(lg sm)
      assert features["color"] == ~w(primary)
      refute Map.has_key?(features, "kind")
    end

    test "a literal argument is not an attribute and binds nothing" do
      comp = %{
        "attrs" => [attr("kind")],
        "template" => ~s|<div class={color_variant("default", @kind)}>|,
        "helpers" => [
          %{
            "name" => "color_variant",
            "discriminators" => [discriminator("color", ~w(primary))]
          }
        ]
      }

      assert Inspector.features(comp) == %{"kind" => ~w(primary)}
    end

    # AN AXIS ON EVERY HELPER IS THE GENERATOR'S, NOT THE COMPONENT'S. Chelekom builds
    # `chelekom-grid` and `chelekom-flex` from one source, so its exporter stamps a `type` axis
    # (`flex` | `grid`) onto all eighteen of the grid's helpers. `bind/2` then found one spare axis
    # and one spare attribute at `place_self_class(@place_self)` and paired them — putting a
    # `flex | grid` picker on CSS `place-self`, the only non-text control that component had.
    test "an axis carried by every helper binds to nothing" do
      comp = %{
        "attrs" => [attr("cols"), attr("place_self")],
        "template" => ~s|<div class={[cols_class(@cols), place_self_class(@place_self)]}>|,
        "helpers" => [
          %{"name" => "cols_class", "discriminators" => [discriminator("type", ~w(grid))]},
          %{"name" => "place_self_class", "discriminators" => [discriminator("type", ~w(flex))]}
        ]
      }

      features = Inspector.features(comp)

      refute Map.has_key?(features, "place_self"),
             "the kit's own generator axis is not an option list for a CSS property"

      refute Map.has_key?(features, "cols")
    end

    # The same shape with the axis on ONE helper is a real binding and must survive.
    test "an axis carried by a single helper still binds" do
      comp = %{
        "attrs" => [attr("cols"), attr("kind")],
        "template" => ~s|<div class={[cols_class(@cols), color_variant("default", @kind)]}>|,
        "helpers" => [
          %{"name" => "cols_class", "discriminators" => [discriminator("type", ~w(grid))]},
          %{"name" => "color_variant", "discriminators" => [discriminator("color", ~w(primary))]}
        ]
      }

      assert Inspector.features(comp)["kind"] == ~w(primary)
    end
  end

  describe "a column count" do
    # A ROW OF SHAPES, NOT A WORD TO SPELL. `chelekom-grid` asks for its column count in a text box
    # whose placeholder is the WORD "twelve", so `4` does nothing and the author has to guess `four`.
    test "is a picker when the kit says how many it can lay out" do
      attr = %{
        "name" => "cols",
        "type" => "string",
        "opts" => %{"values" => ~w(one two three four)}
      }

      assert Inspector.widget(attr) == {:columns, ~w(one two three four)}
    end

    test "an explicit editor hint says so too" do
      attr = %{
        "name" => "tracks",
        "type" => "string",
        "opts" => %{"editor" => "columns", "values" => ~w(1 2 3)}
      }

      assert Inspector.widget(attr) == {:columns, ~w(1 2 3)}
    end

    # WHOLE NAME, NOT PARTS. `named?/2` splits on `_`, so a bare `cols` would also catch `auto_cols`
    # — which sizes implicitly created tracks and has nothing to draw.
    test "auto_cols is not a column count" do
      attr = %{"name" => "auto_cols", "type" => "string", "opts" => %{"values" => ~w(one two)}}

      refute match?({:columns, _}, Inspector.widget(attr))
    end

    # Without a vocabulary there is nothing to draw, and a text box is the honest fallback.
    test "no value list means no picker" do
      attr = %{"name" => "cols", "type" => "string", "opts" => %{}}

      assert Inspector.widget(attr) == :text
    end
  end

  describe "the heuristics that were lying" do
    # `border` in this kit is a WIDTH token — the template calls `border_size(@border, @variant)` and
    # the values are none/extra_small/…/large. Reading the word as a colour drew a hex swatch for 60
    # of the panel's 70 colour controls.
    test "border is a width, not a colour" do
      refute Inspector.widget(attr("border")) == :color
      assert Inspector.widget(attr("border")) == :text
    end

    test "an attribute that really is a colour still gets the swatch" do
      assert Inspector.widget(attr("color")) == :color
      assert Inspector.widget(attr("border_color")) == :color
      assert Inspector.widget(attr("background")) == :color
    end

    # Four kit attrs ship a JSON `null` in their value list. It measured as a zero-length string, so
    # it passed the segmented test and rendered as a blank pill that wrote "" when clicked.
    test "a nil in the value list is dropped, not rendered as a blank option" do
      widget = Inspector.widget(attr("type", "string", %{"values" => ["button", "submit", nil]}))

      assert widget == {:segmented, ["button", "submit"]}
    end

    test "a list of nothing but nil falls back to the ordinary heuristics" do
      assert Inspector.widget(attr("whatever", "string", %{"values" => [nil]})) == :text
    end

    test "features/1 drops nils too, so the fold agrees with the widget" do
      comp = component([attr("type", "string", %{"values" => ["button", nil]})])

      assert Inspector.features(comp) == %{"type" => ["button"]}
    end
  end

  describe "widget/2" do
    test "a boolean attribute gets a toggle" do
      assert Inspector.widget(attr("disabled", "boolean")) == :toggle
    end

    # The bundle stating it outright, which is the answer that scales — a name list cannot be made
    # right by adding more names to it.
    test "an editor hint beats every guess" do
      assert Inspector.widget(attr("name", "string", %{"editor" => "icon"})) == :icon
      assert Inspector.widget(attr("icon", "string", %{"editor" => "text"})) == :text
    end

    # THE CONTRACT A KIT NOBODY HERE HAS SEEN CAN WRITE. Everything else in this module reads how
    # CHELEKOM happens to spell its attributes; `opts.editor` is the kit saying what it means, and it
    # is the only part of the panel a third-party author can rely on. Each accepted value is pinned
    # here, because a hint that silently does nothing is worse than no hint — the author has said
    # something and been ignored.
    test "every editor a kit may declare is honoured" do
      for {declared, expected} <- [
            {"color", :color},
            {"icon", :icon},
            {"media", :media},
            {"url", :url},
            {"number", {:number, nil, nil, 1}},
            {"toggle", :toggle},
            {"textarea", :textarea},
            {"text", :text}
          ] do
        assert Inspector.widget(attr("whatever", "string", %{"editor" => declared})) == expected,
               "a kit declaring editor: #{inspect(declared)} did not get #{inspect(expected)}"
      end
    end

    # The two that read the attribute's own list rather than standing alone.
    test "select and columns are drawn from the values the attribute declares" do
      values = %{"editor" => "select", "values" => ~w(one two three)}
      assert Inspector.widget(attr("pick", "string", values)) == {:segmented, ~w(one two three)}

      cols = %{"editor" => "columns", "values" => ~w(2 3 4)}
      assert Inspector.widget(attr("layout", "string", cols)) == {:columns, ~w(2 3 4)}
    end

    # `editors/0` is what a kit author reads instead of guessing, so it has to BE the list the code
    # honours — not a comment beside it that drifts.
    test "editors/0 names exactly what is honoured" do
      for declared <- Inspector.editors() do
        widget =
          Inspector.widget(attr("x", "string", %{"editor" => declared, "values" => ~w(a b)}))

        refute widget == :text and declared != "text",
               "editors/0 lists #{inspect(declared)}, but declaring it falls through to a text box"
      end
    end

    # `action` READS AS A URL ONLY ON A FORM, and `named?/2` matches any underscore-separated part,
    # so it claimed a position, two CSS classes and an event handler. Four attributes in the kit
    # contain the word; none is an address. A form that genuinely has one declares it.
    test "action is not a url word" do
      assert Inspector.widget(attr("action_position")) == :text
      assert Inspector.widget(attr("action_wrapper_class")) == :text
      assert Inspector.widget(attr("on_action")) == :text

      assert Inspector.widget(attr("action", "string", %{"editor" => "url"})) == :url
    end

    # A DECLARATION IS NOT ARGUED WITH. It is read before the value list too — a kit that ships
    # options AND says "this is a colour" means the swatch, not a dropdown of hex strings.
    test "a declaration wins over the attribute's own value list" do
      swatch = %{"editor" => "color", "values" => ~w(#fff #000)}

      assert Inspector.widget(attr("shade", "string", swatch)) == :color
    end

    # THE FORWARD-COMPATIBILITY PROPERTY. A bundle written against a LATER version of this editor
    # names a control this one has never heard of. It must lose the refinement, not the widget — a
    # kit from the future should degrade to a sensible guess rather than to a broken panel.
    test "an editor this version does not know degrades to inference, never to a crash" do
      unknown = %{"editor" => "colour-wheel-3d"}

      assert Inspector.widget(attr("background", "string", unknown)) == :color
      assert Inspector.widget(attr("disabled", "boolean", unknown)) == :toggle
      assert Inspector.widget(attr("mystery", "string", unknown)) == :text
    end

    # AND DECLARING NOTHING IS STILL SUPPORTED. The heuristics are the fallback, not the plan; a kit
    # that says nothing must still get sensible controls, or "third-party support" means "rewrite
    # your exporter first".
    test "a kit that declares no editor at all still gets sensible controls" do
      assert Inspector.widget(attr("disabled", "boolean")) == :toggle
      assert Inspector.widget(attr("background")) == :color
      assert Inspector.widget(attr("href")) == :url
      assert Inspector.widget(attr("count", "integer")) == {:number, nil, nil, 1}
    end

    # The one component that IS an icon calls its attribute `name`, so no name list can catch it —
    # and it is the control where a picker matters most. This is what makes an install that has not
    # re-exported its bundle behave correctly.
    test "`name` on a component whose name ends in -icon is an icon" do
      component = %{"name" => "chelekom-icon", "attrs" => []}

      assert Inspector.widget(attr("name"), %{}, component) == :icon
      assert Inspector.widget(attr("name"), %{}, %{"name" => "chelekom-navbar"}) == :text
      assert Inspector.widget(attr("name")) == :text
    end

    test "a short option list gets a segmented control" do
      assert Inspector.widget(attr("variant"), %{"variant" => ~w(default filled)}) ==
               {:segmented, ~w(default filled)}
    end

    test "a long option list gets a select" do
      values = ~w(primary secondary success danger warning info light dark)

      assert Inspector.widget(attr("color"), %{"color" => values}) == {:select, values}
    end

    test "a list of long values gets a select even when it is short" do
      values = ~w(extra_large_thing another_long_one)

      assert Inspector.widget(attr("size"), %{"size" => values}) == {:select, values}
    end

    test "numeric attributes get a stepper carrying min, max and step" do
      assert Inspector.widget(attr("count", "integer", %{"min" => 1, "max" => 9, "step" => 2})) ==
               {:number, 1, 9, 2}

      assert Inspector.widget(attr("ratio", "float")) == {:number, nil, nil, 1}
    end

    test "colour-named attributes get a swatch when they have no option list" do
      assert Inspector.widget(attr("color")) == :color
      assert Inspector.widget(attr("border_color")) == :color
    end

    test "a colour-named attribute with options prefers the options" do
      assert Inspector.widget(attr("color"), %{"color" => ~w(a b)}) == {:segmented, ~w(a b)}
    end

    test "url, icon and media names get their own widgets" do
      assert Inspector.widget(attr("href")) == :url
      assert Inspector.widget(attr("start_icon")) == :icon
      assert Inspector.widget(attr("image_url")) == :media
    end

    test "a long doc string gets a textarea" do
      long = String.duplicate("explanation ", 12)

      assert Inspector.widget(%{"name" => "content", "type" => "string", "doc" => long}) ==
               :textarea
    end

    test "the global catch-all and struct attributes are recognised" do
      assert Inspector.widget(attr("rest", "global")) == :global

      assert Inspector.widget(%{"name" => "user", "type" => "struct", "struct_name" => "User"}) ==
               {:struct, "User"}
    end

    test "anything else falls back to a text input" do
      assert Inspector.widget(attr("label")) == :text
    end

    test "an explicit editor hint overrides every heuristic" do
      assert Inspector.widget(attr("label", "string", %{"editor" => "textarea"})) == :textarea
      assert Inspector.widget(attr("tone", "string", %{"editor" => "color"})) == :color
      assert Inspector.widget(attr("href", "string", %{"editor" => "textarea"})) == :textarea
    end

    test "a name that merely contains a keyword is not mistaken for it" do
      assert Inspector.widget(attr("colorful")) == :text
      assert Inspector.widget(attr("preference")) == :text
    end
  end

  describe "labels and metadata" do
    test "humanizes an attribute name" do
      assert Inspector.label(attr("start_icon")) == "Start icon"
      assert Inspector.label(attr("color")) == "Color"
      assert Inspector.label("phx-no-format") == "Phx no format"
    end

    test "required, doc and default are read from opts" do
      a = attr("size", "string", %{"required" => true, "doc" => "The size", "default" => "md"})

      assert Inspector.required?(a)
      assert Inspector.doc(a) == "The size"
      assert Inspector.default(a) == "md"
    end

    test "an attribute with no opts is not required" do
      refute Inspector.required?(attr("size"))
    end
  end

  describe "grouped/1" do
    test "sorts attributes into the panel's sections" do
      comp =
        component([
          attr("padding"),
          attr("color"),
          attr("disabled", "boolean"),
          attr("title"),
          attr("mystery")
        ])

      grouped =
        Map.new(Inspector.grouped(comp), fn {group, attrs} ->
          {group, Enum.map(attrs, &Inspector.name/1)}
        end)

      assert grouped["Layout"] == ["padding"]
      assert grouped["Appearance"] == ["color"]
      assert grouped["Behavior"] == ["disabled"]
      assert grouped["Content"] == ["title"]
      assert grouped["Properties"] == ["mystery"]
    end

    test "global attributes are excluded — they are the HTML attributes editor, not a property" do
      comp = component([attr("rest", "global"), attr("color")])

      names =
        Inspector.grouped(comp)
        |> Enum.flat_map(fn {_g, attrs} -> Enum.map(attrs, &Inspector.name/1) end)

      assert names == ["color"]
    end

    test "sections come back in panel order" do
      comp = component([attr("mystery"), attr("title"), attr("padding")])

      # Content leads: the words on an element are what an author reaches for first. "Properties" is
      # the leftovers by construction but the biggest group on most components, so it does not sit
      # last either.
      assert Enum.map(Inspector.grouped(comp), &elem(&1, 0)) == [
               "Content",
               "Properties",
               "Layout"
             ]
    end

    # WHAT IT LOOKS LIKE OUTRANKS WHAT IT IS WIRED TO. On a kit component the Properties bucket is
    # `class`, `id` and `wrapper_class` — plumbing — and it used to be drawn ABOVE Appearance. On a
    # jumbotron, which declares no Content attrs of its own, that made Class and Id the first thing
    # the panel showed and pushed `variant` to the third field of the second section.
    test "appearance outranks the leftovers bucket" do
      comp = component([attr("mystery"), attr("variant"), attr("class")])

      assert Enum.map(Inspector.grouped(comp), &elem(&1, 0)) == ["Appearance", "Properties"]
    end

    # Sorted by name these came back `color`, `font_weight`, `variant` — the property that changes
    # what the component IS, last.
    test "and inside it the two knobs that change everything lead" do
      comp =
        component([
          attr("font_weight"),
          attr("shadow"),
          attr("variant"),
          attr("color")
        ])

      grouped =
        Map.new(Inspector.grouped(comp), fn {g, a} -> {g, Enum.map(a, &Inspector.name/1)} end)

      assert grouped["Appearance"] == ["variant", "color", "font_weight", "shadow"]
    end

    # `font_weight` is not `weight`. A prefix match here would drag half a component's surface to the
    # top of its section on the strength of a shared first syllable.
    test "and the lead is an exact name, not a prefix" do
      comp = component([attr("colorway"), attr("color")])

      grouped =
        Map.new(Inspector.grouped(comp), fn {g, a} -> {g, Enum.map(a, &Inspector.name/1)} end)

      assert grouped["Appearance"] == ["color"]
      assert grouped["Properties"] == ["colorway"]
    end
  end

  describe "the two form sections" do
    defp parsed(template) do
      {:ok, tree} = Tree.parse(template)
      tree
    end

    defp node_named(tree, tag), do: tree |> Tree.walk() |> Enum.find(&(&1.tag == tag))

    defp one_form do
      parsed(
        ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact_validate" phx-submit="contact_submit"><input type="text" name="loose" /><.input field={f[:email]} type="email" /></.form>)
      )
    end

    defp tagged_form do
      parsed(
        ~s(<.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><.input field={f[:email]} type="email" /></.form>)
      )
    end

    defp code(entries), do: Map.merge(%{events: [], infos: [], helpers: []}, Map.new(entries))

    test "both are ordinary inspector-section descriptors" do
      for section <- Inspector.form_sections() do
        assert section.kind == :inspector_section
        assert Descriptor.key(section) in ~w(form validation)
        refute section.config["controls"] == []
      end
    end

    test "they sort between State and Layout, where a form's own name belongs" do
      assert Enum.map(Inspector.form_sections(), &Descriptor.priority/1) == [35, 45]
    end

    test "the Form section carries the seed and the success message, and nothing else" do
      assert Enum.map(Inspector.form_controls(), & &1.key) == ~w(seed success)
    end

    test "the Validation section writes real HTML attributes" do
      assert Enum.map(Inspector.validation_controls(), & &1.attr) ==
               ~w(required minlength maxlength min max pattern data-format data-confirms)
    end

    test "the Form section applies to a form and to nothing else" do
      tree = one_form()

      assert Inspector.form_node?(node_named(tree, ".form"))
      refute Inspector.form_node?(node_named(tree, ".input"))
    end

    test "the Validation section applies to a bound field inside a form" do
      tree = one_form()

      assert Inspector.validated_node?(tree, node_named(tree, ".input"))
    end

    # A loose `<input name="loose">` is a field to the compiler and NOT a bound one, so it has no key
    # for a rule to hang off. Offering rules on it would write constraints the changeset never reads.
    test "and not to an unbound control, even inside a form" do
      tree = one_form()

      refute Inspector.validated_node?(tree, node_named(tree, "input"))
    end

    test "and not to a bound field with no form above it" do
      tree = parsed(~s(<div><.input field={f[:email]} type="email" /></div>))

      refute Inspector.validated_node?(tree, node_named(tree, ".input"))
    end

    test "the seed is read off the form rather than stored anywhere" do
      assert Inspector.form_seed(node_named(one_form(), ".form")) == "contact"
    end

    # ONE BATCH, ALL FIVE. Five separate ops would be five undo steps, and four of them would leave a
    # page whose form id, params, page assign and events disagree.
    test "a rename issues one op per derived name and no others" do
      form = node_named(one_form(), ".form")

      ops = Inspector.rename_ops(form, "Sales Enquiry", nil)

      assert Enum.map(ops, & &1.name) == Naming.derived()
      assert Enum.all?(ops, &(&1.kind == :set_attr and &1.node_id == form.id))

      assert Enum.map(ops, & &1.value) == [
               "sales_enquiry-form",
               ":sales_enquiry",
               "assigns[:sales_enquiry_form]",
               "sales_enquiry_validate",
               "sales_enquiry_submit"
             ]
    end

    test "a rename with a token writes it into both event names" do
      ops = Inspector.rename_ops(node_named(one_form(), ".form"), "Sales Enquiry", "k7m2q")

      assert Enum.map(ops, & &1.value) == [
               "sales_enquiry-form",
               ":sales_enquiry",
               "assigns[:sales_enquiry_form]",
               "sales_enquiry-k7m2q-validate",
               "sales_enquiry-k7m2q-submit"
             ]
    end

    test "the two that are expressions are written as expressions" do
      ops = Inspector.rename_ops(node_named(one_form(), ".form"), "contact", nil)

      assert Enum.map(ops, &{&1.name, &1.value_kind}) == [
               {"id", :string},
               {"as", :expr},
               {"for", :expr},
               {"phx-change", :string},
               {"phx-submit", :string}
             ]
    end

    test "a seed the form already holds is not a conflict with itself" do
      tree = one_form()

      assert Inspector.seed_refusal(tree, node_named(tree, ".form"), "contact") == nil
    end

    test "a seed another form holds is refused, minted before it is compared" do
      tree =
        parsed(
          ~s(<div><.form :let={f} as={:contact} for={assigns[:contact_form]}></.form><.form :let={g} as={:signup} for={assigns[:signup_form]}></.form></div>)
        )

      [_first, second] = tree |> Tree.walk() |> Enum.filter(&Inspector.form_node?/1)

      assert Inspector.seed_refusal(tree, second, "Contact") =~ "already called"
      assert Inspector.seed_refusal(tree, second, "quote") == nil
    end

    test "a rename says which hand-written handlers stop being called" do
      form = node_named(one_form(), ".form")
      events = [%{name: "contact_submit"}, %{name: "something_else"}]

      assert Inspector.bound_handlers(form, events) == ["contact_submit"]

      assert Inspector.rename_warning(form, code(events: events)) ==
               "contact_submit on the Handlers tab will stop being called."

      assert Inspector.rename_warning(form, code([])) == nil
    end

    test "a tagged form's own handlers follow it, so they raise no warning" do
      form = node_named(tagged_form(), ".form")
      events = [%{name: "contact-k7m2q-submit", code: "{:noreply, socket}"}]

      assert Inspector.rename_warning(form, code(events: events)) == nil
    end

    test "stored code that mentions the form's seed raises a plain warning, wherever it is" do
      form = node_named(tagged_form(), ".form")

      for {tab, text} <- [
            events: "socket.assigns[:contact_form]",
            infos: ~S|params["contact"]|,
            helpers: "Map.get(assigns, :contact)"
          ] do
        assert Inspector.rename_warning(form, code([{tab, [%{"name" => "x", "code" => text}]}])) ==
                 "Code someone wrote for this form stops running if you rename it. Ask them first."
      end
    end

    test "a longer name that only starts with the seed is not a mention" do
      form = node_named(tagged_form(), ".form")

      for text <- [":contact_2", ":contacts", ":contact_formal", ~S|"contacts"|, "contact"] do
        assert Inspector.rename_warning(form, code(events: [%{code: text}])) == nil,
               "#{text} does not name the contact form"
      end
    end

    test "rename_token/3 keeps a tagged form's token" do
      tree = tagged_form()

      assert Inspector.rename_token(tree, node_named(tree, ".form"), []) == "k7m2q"

      assert Inspector.rename_token(tree, node_named(tree, ".form"), [], code_allowed?: true) ==
               "k7m2q"
    end

    test "rename_token/3 mints one for an untagged form nothing answers by name" do
      tree = one_form()
      token = Inspector.rename_token(tree, node_named(tree, ".form"), [%{name: "save"}])

      assert token =~ ~r/^[a-z2-7]{5}$/
    end

    test "rename_token/3 keeps the untagged names while a handler answers the form by name" do
      tree = one_form()

      assert Inspector.rename_token(tree, node_named(tree, ".form"), [%{name: "contact_submit"}]) ==
               nil
    end

    defp c_form do
      parsed(
        ~s(<.form :let={f} id="c-form" as={:c} for={assigns[:c_form]} phx-change="c_validate" phx-submit="c_submit"></.form>)
      )
    end

    # THE NAME BOX COMMITS AS IT IS TYPED. After the first commit the form is `c`, and the handler
    # answered the form the rename began on.
    test "rename_token/4 keeps the untagged names while a handler answered the origin by name" do
      tree = c_form()
      origin = node_named(one_form(), ".form")
      events = [%{name: "contact_submit"}]

      assert Inspector.rename_token(tree, node_named(tree, ".form"), events, origin: origin) ==
               nil
    end

    test "rename_token/3 mints when a stored untagged handler answers another form's old name" do
      tree = c_form()

      assert Inspector.rename_token(tree, node_named(tree, ".form"), [%{name: "contact_submit"}]) =~
               ~r/^[a-z2-7]{5}$/
    end

    # A DELETED FORM'S HANDLER NEVER ANSWERS A RENAMED ONE (spec 4.5).
    test "renaming a form to a deleted form's name does not reach its stored handler" do
      tree =
        parsed(
          ~s(<.form :let={f} id="newsletter-form" as={:newsletter} for={assigns[:newsletter_form]} phx-change="newsletter_validate" phx-submit="newsletter_submit"></.form>)
        )

      node = node_named(tree, ".form")
      events = [%{name: "contact_submit", code: "{:noreply, socket}"}]

      submit =
        node
        |> Inspector.rename_ops("Contact", Inspector.rename_token(tree, node, events))
        |> Enum.find(&(&1.name == "phx-submit"))
        |> Map.fetch!(:value)

      assert submit =~ ~r/^contact-[a-z2-7]{5}-submit$/
      refute PageForms.answered?(events, submit)
    end

    test "rename_token/3 mints for an untagged form whatever other handlers are called" do
      tree = one_form()

      for name <- ~w(search_submit newsletter_validate) do
        assert Inspector.rename_token(tree, node_named(tree, ".form"), [%{name: name}]) =~
                 ~r/^[a-z2-7]{5}$/,
               "#{name} is not the contact form's"
      end
    end

    # A CODE AUTHOR'S HANDLERS MOVE WITH THE FORM (spec 0.8): the rename tags it, and `retagged/3`
    # says which stored names take the token.
    test "rename_token/4 mints for a code author even while a handler answers the form by name" do
      tree = one_form()
      node = node_named(tree, ".form")
      events = [%{name: "contact_submit"}]

      token = Inspector.rename_token(tree, node, events, code_allowed?: true)

      assert token =~ ~r/^[a-z2-7]{5}$/

      assert Inspector.retagged(node, token, events) == %{
               "contact_submit" => "contact-#{token}-submit"
             }
    end

    test "retagged/3 maps only the untagged names a stored handler answers" do
      node = node_named(one_form(), ".form")
      both = [%{"name" => "contact_validate"}, %{"name" => "contact_submit"}, %{"name" => "save"}]

      assert Inspector.retagged(node, "k7m2q", both) == %{
               "contact_validate" => "contact-k7m2q-validate",
               "contact_submit" => "contact-k7m2q-submit"
             }

      assert Inspector.retagged(node, nil, both) == %{}
      assert Inspector.retagged(node, "k7m2q", [%{name: "save"}]) == %{}

      tagged = node_named(tagged_form(), ".form")
      assert Inspector.retagged(tagged, "k7m2q", [%{name: "contact-k7m2q-submit"}]) == %{}
    end

    test "a code author is not told a handler that moves with the form will stop" do
      form = node_named(one_form(), ".form")
      events = [%{name: "contact_submit", code: "{:noreply, socket}"}]

      assert Inspector.rename_warning(form, code(events: events), true) == nil

      mentioned = [%{name: "save", code: "socket.assigns[:contact_form]"}]

      assert Inspector.rename_warning(form, code(events: events ++ mentioned), true) ==
               "Code someone wrote for this form stops running if you rename it. Ask them first."
    end

    test "an event declared without a name does not match a form that has none either" do
      tree = parsed(~s(<.form as={:contact} for={assigns[:contact_form]}></.form>))

      assert Inspector.bound_handlers(node_named(tree, ".form"), [%{}]) == []
    end

    test "a switch reads presence and a text control reads the attribute" do
      tree = parsed(~s(<input name="a" required minlength="4" />))
      node = node_named(tree, "input")
      [required, minlength | _rest] = Inspector.validation_controls()

      assert Inspector.rule_value(node, required) == true
      assert Inspector.rule_value(node, minlength) == "4"
    end

    test "and both read false or nil when the attribute is absent" do
      tree = parsed(~s(<input name="a" />))
      node = node_named(tree, "input")
      [required, minlength | _rest] = Inspector.validation_controls()

      assert Inspector.rule_value(node, required) == false
      assert Inspector.rule_value(node, minlength) == nil
    end

    # A RULE TURNED OFF IS DELETED. `required=""` is still required to a browser and `minlength=""`
    # reads back as no rule on the server, so a control that only ever wrote would leave the two
    # disagreeing about what is valid.
    test "turning a rule off deletes its attribute" do
      tree = parsed(~s(<input name="a" required minlength="4" />))
      node = node_named(tree, "input")
      [required, minlength | _rest] = Inspector.validation_controls()

      assert Inspector.rule_op(node, required, "false") ==
               %{kind: :delete_attr, node_id: node.id, name: "required"}

      assert Inspector.rule_op(node, minlength, "  ") ==
               %{kind: :delete_attr, node_id: node.id, name: "minlength"}
    end

    test "turning one on writes it, a switch as a bare attribute" do
      tree = parsed(~s(<input name="a" />))
      node = node_named(tree, "input")
      [required, minlength | _rest] = Inspector.validation_controls()

      assert Inspector.rule_op(node, required, "true") ==
               %{
                 kind: :set_attr,
                 node_id: node.id,
                 name: "required",
                 value: "",
                 value_kind: :boolean
               }

      assert Inspector.rule_op(node, minlength, "4") ==
               %{
                 kind: :set_attr,
                 node_id: node.id,
                 name: "minlength",
                 value: "4",
                 value_kind: :string
               }
    end
  end

  # Two forms, each with its field and Send button in a column of a grid in a card: Phoenix's own,
  # and Chelekom's Form Wrapper wired as a page form.
  describe "form_story/2, for someone who does not write code" do
    @story_page ~s(<div><.form :let={f} id="contact-form" as={:contact} for={assigns[:contact_form]} phx-change="contact-k7m2q-validate" phx-submit="contact-k7m2q-submit"><div class="card"><div class="grid"><div class="col"><input name={f[:email].name} /></div><div class="col"><button type="submit">Send</button></div></div></div></.form>) <>
                  ~s(<.component component_name="chelekom-form-wrapper" site="Global" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit"><div class="card"><div class="grid"><div class="col"><input name={w[:email].name} /></div><div class="col"><button type="submit">Join</button></div></div></div></.component></div>)

    defp story_forms do
      {:ok, tree} = Tree.parse(@story_page)
      tree |> Tree.walk() |> Enum.filter(&PageForms.form?/1)
    end

    defp stored(names), do: %{events: Enum.map(names, &%{name: &1, code: "{:noreply, socket}"})}

    test "with no code: the fields are checked, and nothing stores or sends it" do
      for form <- story_forms() do
        assert Inspector.form_story(form, %{events: []}) ==
                 {"While a visitor types: the fields are checked.",
                  "When they press Send: nothing stores or sends what visitors type yet."}
      end
    end

    test "code written for one form's submit is that form's alone" do
      [contact, news] = story_forms()
      record = stored(["contact-k7m2q-submit"])

      assert elem(Inspector.form_story(contact, record), 1) ==
               "When they press Send: your own code receives it."

      assert elem(Inspector.form_story(news, record), 1) ==
               "When they press Send: nothing stores or sends what visitors type yet."
    end

    test "the default code nobody edited still stores and sends nothing" do
      [_contact, news] = story_forms()
      sample = LiveViewCompiler.form_handler_sample(:submit, "news-p3xa6-submit")

      assert elem(
               Inspector.form_story(news, %{events: [%{name: "news-p3xa6-submit", code: sample}]}),
               1
             ) ==
               "When they press Send: nothing stores or sends what visitors type yet."
    end

    test "code on change, or no change event, is said too" do
      [contact, _news] = story_forms()

      assert elem(Inspector.form_story(contact, stored(["contact-k7m2q-validate"])), 0) ==
               "While a visitor types: your own code runs."

      {:ok, tree} =
        Tree.parse(String.replace(@story_page, ~s( phx-change="contact-k7m2q-validate"), ""))

      bare = tree |> Tree.walk() |> Enum.find(&PageForms.form?/1)

      assert elem(Inspector.form_story(bare, nil), 0) ==
               "While a visitor types: nothing is checked until they press Send."
    end

    test "a form that posts to its own address says it goes there" do
      {:ok, tree} =
        @story_page
        |> String.replace(~s( phx-submit="contact-k7m2q-submit"), ~s( action="/thanks"))
        |> Tree.parse()

      [contact, news] = tree |> Tree.walk() |> Enum.filter(&PageForms.form?/1)

      assert elem(Inspector.form_story(contact, nil), 1) ==
               "When they press Send: it goes to the web address the form names."

      assert elem(Inspector.form_story(news, nil), 1) ==
               "When they press Send: nothing stores or sends what visitors type yet."
    end

    test "never says an event name or a tag" do
      for form <- story_forms(), record <- [nil, stored(["contact-k7m2q-submit"])] do
        {typing, sending} = Inspector.form_story(form, record)
        refute typing <> sending =~ ~r/k7m2q|p3xa6|submit|validate|contact|news/
      end
    end
  end

  describe "form_part/2, the header pill" do
    setup %{chelekom: rows} do
      button = Enum.find(rows, &(&1.name == "chelekom-button"))

      %{kit: [%{button | name: "my-kit-button"} | rows] ++ Factory.renamed_form_pair(rows)}
    end

    defp card(inner),
      do:
        ~s(<.component component_name="chelekom-card" site="Global"><div class="grid"><div class="col">) <>
          inner <> "</div></div></.component>"

    defp in_form(inner),
      do:
        ~s(<.form :let={f} id="q-form" as={:q} for={assigns[:q_form]}><.input field={f[:email]} type="email" />) <>
          card(inner) <> "</.form>"

    defp part(source, kit, pick) do
      {:ok, tree} = Tree.parse(source)
      node = tree |> Tree.walk() |> Enum.find(pick)

      Inspector.form_part(%{tree: tree, components: kit}, node)
    end

    defp named(name), do: &(Tree.Node.component_name(&1) == name)

    test "a kit button deep inside a form is its Submit button", %{kit: kit} do
      source =
        in_form(~s(<.component component_name="chelekom-button" site="Global">Send</.component>))

      assert part(source, kit, named("chelekom-button")) == :submit
    end

    test "one that says type=button there does not send the form", %{kit: kit} do
      source =
        in_form(
          ~s(<.component component_name="chelekom-button" site="Global" type="button">Go</.component>)
        )

      assert part(source, kit, named("chelekom-button")) == :not_submit
    end

    test "one given a link attribute is still a button that sends it", %{kit: kit} do
      source =
        in_form(
          ~s(<.component component_name="chelekom-button" site="Global" navigate="/pricing">Go</.component>)
        )

      assert part(source, kit, named("chelekom-button")) == :submit

      assert part(in_form(~s(<.button navigate="/pricing">Go</.button>)), kit, named("button")) ==
               :not_submit
    end

    test "outside every form it is just a button, whatever its type says", %{kit: kit} do
      for attrs <- ["", ~s( type="submit"), ~s( type="button")] do
        source =
          ~s(<section>) <>
            card(
              ~s(<.component component_name="chelekom-button" site="Global"#{attrs}>Go</.component>)
            ) <>
            "</section>"

        assert part(source, kit, named("chelekom-button")) == :button, attrs
      end
    end

    test "a renamed copy answers the same", %{kit: kit} do
      source =
        in_form(~s(<.component component_name="my-kit-button" site="Global">Send</.component>))

      assert part(source, kit, named("my-kit-button")) == :submit
    end

    test "the CMS's own button and HTML's own button inside a form send it", %{kit: kit} do
      assert part(in_form("<.button>Send</.button>"), kit, named("button")) == :submit
      assert part(in_form("<button>Send</button>"), kit, &(&1.tag == "button")) == :submit

      assert part(in_form(~s(<.button type="button">Open</.button>)), kit, named("button")) ==
               :not_submit
    end

    # A kit button whose `type` is an atom: the Inspector writes the author's pick as `type={:submit}`.
    @atom_button %{
      name: "acme-atom-button",
      attrs: [
        %{
          "name" => "type",
          "type" => "atom",
          "opts" => %{"default" => "button", "values" => ~w(button submit)}
        }
      ],
      slots: [%{"name" => "inner_block"}],
      template: ~S|<button type={@type}>{render_slot(@inner_block)}</button>|
    }

    test "a type written as a literal expression is read as the word it holds", %{kit: kit} do
      kit = [@atom_button | kit]

      atom_button =
        &~s(<.component component_name="acme-atom-button" site="Global" type={#{&1}}>Go</.component>)

      assert part(in_form(atom_button.(":submit")), kit, named("acme-atom-button")) == :submit
      assert part(in_form(atom_button.(":button")), kit, named("acme-atom-button")) == :not_submit

      assert part(in_form(~S(<button type={"submit"}>Go</button>)), kit, &(&1.tag == "button")) ==
               :submit
    end

    test "a kit input that could send is not a button where it is placed as a text box", %{
      kit: kit
    } do
      input = %{
        name: "acme-input",
        attrs: [
          %{
            "name" => "type",
            "type" => "string",
            "opts" => %{"default" => "text", "values" => ~w(text email submit)}
          }
        ],
        slots: [],
        template: ~S(<input type={@type} />)
      }

      placed = &in_form(~s(<.component component_name="acme-input" site="Global"#{&1} />))

      assert part(placed.(~s( type="email")), [input | kit], named("acme-input")) == nil
      assert part(placed.(~s( type="submit")), [input | kit], named("acme-input")) == :submit
    end

    test "a button that computes its type is only a Button: whether it sends cannot be read", %{
      kit: kit
    } do
      assert part(
               in_form(~S(<button type={assigns[:kind]}>Go</button>)),
               kit,
               &(&1.tag == "button")
             ) ==
               :button

      assert part(
               in_form(
                 ~S(<.component component_name="chelekom-button" site="Global" type={assigns[:t]}>Go</.component>)
               ),
               kit,
               named("chelekom-button")
             ) == :button
    end

    test "a submit input written in capitals is the Submit button, not a Field", %{kit: kit} do
      for input <- [~s(<input type="Submit" value="Send" />), ~s(<input type=" SUBMIT " />)] do
        assert part(in_form(input), kit, &(&1.tag == "input")) == :submit, input
      end
    end

    test "a form, a kit form wrapper and a raw form are each a Form", %{kit: kit} do
      assert part(in_form(""), kit, &(&1.tag == ".form")) == :form
      assert part(~s(<form action="/s"></form>), kit, &(&1.tag == "form")) == :form

      wrapper = ~s(<.component component_name="chelekom-form-wrapper" site="Global" for={%{}} />)
      assert part(wrapper, kit, named("chelekom-form-wrapper")) == :form
    end

    test "a field is a Field, inside a form or not", %{kit: kit} do
      assert part(in_form(""), kit, named("input")) == :field
      assert part(~s(<div><input name="q" /></div>), kit, &(&1.tag == "input")) == :field
    end

    test "anything else says nothing", %{kit: kit} do
      assert part(in_form("<p>Hi</p>"), kit, &(&1.tag == "p")) == nil
      assert part(in_form(""), kit, named("chelekom-card")) == nil
      assert Inspector.form_part(%{tree: Tree.new(), components: kit}, nil) == nil
    end

    # A kit form as the palette seeds it, `for={%{}}`: no page assign marks it, its markup does.
    defp in_kit_form(name, inner),
      do:
        ~s(<.component component_name="#{name}" site="Global" :let={f} id="k-form" for={%{}}>) <>
          card(inner) <> "</.component>"

    @kit_parts ~s(<.component component_name="chelekom-text-field" site="Global" field={f[:name]} label="Name" />) <>
                 ~s(<.component component_name="chelekom-button" site="Global">Send</.component>) <>
                 ~s(<.component component_name="chelekom-button" site="Global" type="button">Preview</.component>)

    defp button_parts(source, kit) do
      {:ok, tree} = Tree.parse(source)

      tree
      |> Tree.walk()
      |> Enum.filter(&(Tree.Node.component_name(&1) == "chelekom-button"))
      |> Enum.map(&Inspector.form_part(%{tree: tree, components: kit}, &1))
    end

    test "deep in a kit form's card, whatever the form is called", %{kit: kit} do
      for name <- ~w(chelekom-form-wrapper chelekom-simple-form acme-wrapper acme-simple) do
        source = in_kit_form(name, @kit_parts)

        assert part(source, kit, named(name)) == :form, name
        assert part(source, kit, named("chelekom-text-field")) == :field, name
        assert button_parts(source, kit) == [:submit, :not_submit], name
      end
    end

    test "two forms on one page, each button judged by the form it is in", %{kit: kit} do
      source =
        ~s(<div>) <>
          ~s(<.component component_name="chelekom-button" site="Global">Start</.component>) <>
          in_form(
            ~s(<.component component_name="chelekom-button" site="Global" type="button">Open</.component>)
          ) <>
          in_kit_form(
            "acme-simple",
            ~s(<.component component_name="chelekom-button" site="Global">Join</.component>)
          ) <>
          ~s(</div>)

      assert button_parts(source, kit) == [:button, :not_submit, :submit]
    end
  end

  describe "form_state/2" do
    setup %{chelekom: rows} do
      %{kit: rows ++ Factory.renamed_form_pair(rows)}
    end

    defp state(source, kit, pick) do
      {:ok, tree} = Tree.parse(source)

      tree |> Tree.walk() |> Enum.find(pick) |> Inspector.form_state(kit)
    end

    @wired_kit ~s(<.component component_name="chelekom-form-wrapper" site="Global" :let={w} id="news-form" as={:news} for={assigns[:news_form]} phx-change="news-p3xa6-validate" phx-submit="news-p3xa6-submit">)

    test "a working form, deep fields and all, core or kit", %{kit: kit} do
      wired = @wired_kit <> card(~s(<input name={w[:email].name} />)) <> "</.component>"

      assert state(in_form(""), kit, &(&1.tag == ".form")) == :page_form
      assert state(wired, kit, named("chelekom-form-wrapper")) == :page_form
    end

    test "a kit form that is not wired can be made one, whatever it is called", %{kit: kit} do
      for name <- ~w(chelekom-form-wrapper chelekom-simple-form acme-wrapper acme-simple) do
        assert state(in_kit_form(name, ""), kit, named(name)) == {:idle, true}, name
      end
    end

    test "a raw form cannot be made one where it stands, and a card is no form", %{kit: kit} do
      raw = ~s(<form id="raw">) <> card(~s(<input name="q" />)) <> "</form>"

      assert state(raw, kit, &(&1.tag == "form")) == {:idle, false}
      assert state(in_form(""), kit, named("chelekom-card")) == :none
      assert state(raw, kit, &(&1.tag == "input")) == :none
      assert Inspector.form_state(nil, kit) == :none
    end
  end

  describe "the Form · Phoenix options" do
    setup %{chelekom: rows} do
      %{kit: rows ++ Factory.renamed_form_pair(rows)}
    end

    defp picked(source, pick) do
      {:ok, tree} = Tree.parse(source)
      {tree, tree |> Tree.walk() |> Enum.find(pick)}
    end

    defp keys(controls), do: Enum.map(controls, & &1.key)

    test "a core form is offered every option; a kit wrapper only what it forwards", %{kit: kit} do
      {_tree, core} = picked(in_form(""), &(&1.tag == ".form"))

      {_tree, wrapper} =
        picked(
          @wired_kit <> card(~s(<input name={w[:email].name} />)) <> "</.component>",
          named("chelekom-form-wrapper")
        )

      assert keys(Inspector.phoenix_form_controls(core, kit)) ==
               ~w(novalidate autocomplete auto_recover target)

      assert keys(Inspector.phoenix_form_controls(wrapper, kit)) == ~w(auto_recover)
      assert Inspector.address_takes?(core, kit)
      refute Inspector.address_takes?(wrapper, kit)
    end

    test "defaults read back when absent, and choosing one removes the attribute", %{kit: kit} do
      {_tree, core} = picked(in_form(""), &(&1.tag == ".form"))
      [novalidate, autocomplete, recover, target] = Inspector.phoenix_form_controls(core, kit)

      assert Inspector.rule_value(core, novalidate) == false
      assert Inspector.rule_value(core, autocomplete) == "on"
      assert Inspector.rule_value(core, recover) == true
      assert Inspector.rule_value(core, target) == ""

      assert %{kind: :set_attr, name: "autocomplete", value: "off"} =
               Inspector.rule_op(core, autocomplete, "off")

      assert %{kind: :delete_attr, name: "autocomplete"} =
               Inspector.rule_op(core, autocomplete, "on")

      assert %{kind: :set_attr, name: "phx-auto-recover", value: "ignore"} =
               Inspector.rule_op(core, recover, "false")

      assert %{kind: :delete_attr, name: "phx-auto-recover"} =
               Inspector.rule_op(core, recover, "true")

      assert %{kind: :set_attr, name: "target", value: "_blank"} =
               Inspector.rule_op(core, target, "_blank")

      assert %{kind: :delete_attr, name: "target"} = Inspector.rule_op(core, target, "")

      {_tree, off} =
        picked(
          String.replace(in_form(""), ~s(id="q-form"), ~s(id="q-form" phx-auto-recover="ignore")),
          &(&1.tag == ".form")
        )

      assert Inspector.rule_value(off, recover) == false
    end

    test "Send to another address writes all four together, and empty removes them", %{kit: kit} do
      {tree, core} = picked(in_form(""), &(&1.tag == ".form"))

      assert {:ok, ops} =
               Inspector.address_ops(tree, core, " https://pay.example.com/checkout ", kit)

      assert Enum.map(ops, &{&1.name, &1.value, &1.value_kind}) == [
               {"action", "https://pay.example.com/checkout", :string},
               {"method", "post", :string},
               {"csrf_token", "false", :expr},
               {"phx-trigger-action", "assigns[:q_send]", :expr}
             ]

      assert {:ok, removed} = Inspector.address_ops(tree, core, "  ", kit)

      assert Enum.map(removed, &{&1.kind, &1.name}) ==
               Enum.map(~w(action method csrf_token phx-trigger-action), &{:delete_attr, &1})

      for typed <- ["http://pay.example.com", "pay.example.com", "https://"] do
        assert {:error, "Use a full web address that starts with https://"} =
                 Inspector.address_ops(tree, core, typed, kit),
               typed
      end
    end

    test "an address opens the result in the same tab: it clears New tab and hides the choice", %{
      kit: kit
    } do
      {tree, core} = picked(in_form(""), &(&1.tag == ".form"))

      {blank_tree, blank} =
        picked(
          String.replace(in_form(""), ~s(id="q-form"), ~s(id="q-form" target="_blank")),
          &(&1.tag == ".form")
        )

      assert {:ok, ops} =
               Inspector.address_ops(blank_tree, blank, "https://pay.example.com/checkout", kit)

      assert %{kind: :delete_attr, name: "target"} = List.last(ops)

      assert {:ok, plain} =
               Inspector.address_ops(tree, core, "https://pay.example.com/checkout", kit)

      refute Enum.any?(plain, &(&1.name == "target"))

      {_tree, sending} =
        picked(
          String.replace(
            in_form(""),
            ~s(id="q-form"),
            ~s(id="q-form" action="https://pay.example.com/checkout" method="post" csrf_token={false} phx-trigger-action={assigns[:q_send]})
          ),
          &(&1.tag == ".form")
        )

      assert "target" in keys(Inspector.phoenix_form_controls(core, kit))
      refute "target" in keys(Inspector.phoenix_form_controls(sending, kit))
    end

    test "an address on a form holding a file field turns multipart on, and empty keeps it", %{
      kit: kit
    } do
      {tree, filed} =
        picked(in_form(~s(<input type="file" name="cv" />)), &(&1.tag == ".form"))

      assert {:ok, ops} =
               Inspector.address_ops(tree, filed, "https://pay.example.com/jobs", kit)

      assert %{kind: :set_attr, name: "multipart", value: "true", value_kind: :expr} =
               List.last(ops)

      assert {:ok, removed} = Inspector.address_ops(tree, filed, "", kit)
      refute Enum.any?(removed, &(&1.name == "multipart"))

      {tree, wrapper} =
        picked(
          @wired_kit <> card(~s(<input type="file" name="cv" />)) <> "</.component>",
          named("chelekom-form-wrapper")
        )

      assert {:ok, kit_ops} = Inspector.address_ops(tree, wrapper, "https://pay.example.com", kit)
      refute Enum.any?(kit_ops, &(&1.name == "multipart"))
    end

    test "a file field deep inside is found, in a core form and a kit wrapper", %{kit: kit} do
      for {source, pick} <- [
            {in_form(""), &(&1.tag == ".form")},
            {@wired_kit <> card("") <> "</.component>", named("chelekom-form-wrapper")}
          ] do
        {tree, form} = picked(source, pick)
        refute Inspector.holds_file_field?(tree, form, kit)

        {filed, form} =
          picked(
            String.replace(
              source,
              ~s(<div class="col">),
              ~s(<div class="col"><input type="FILE" name="cv" />)
            ),
            pick
          )

        assert Inspector.holds_file_field?(filed, form, kit)
      end
    end

    test "How it works is a Form control only where the form can carry the choice", %{kit: kit} do
      {tree, core} = picked(in_form(""), &(&1.tag == ".form"))
      page = %{tree: tree, section: "page", components: kit}

      assert [%{key: "how", id: "pb-form-how", widget: {:choices, _pairs}} = how] =
               core |> Inspector.form_controls(page) |> Enum.drop(2)

      assert Inspector.rule_value(core, how) == "send"
      assert how.help =~ "sent when they press Send"

      {_tree, typed} =
        picked(
          String.replace(in_form(""), ~s(id="q-form"), ~s(id="q-form" data-sends-as-typed)),
          &(&1.tag == ".form")
        )

      [_seed, _success, typing] = Inspector.form_controls(typed, page)
      assert Inspector.rule_value(typed, typing) == "typing"
      assert typing.help =~ "There is no Send button."

      assert Inspector.form_controls(core, %{page | section: "layout"}) ==
               Inspector.form_controls()
    end

    test "names it uses are read off the form, and the panel owns them" do
      {_tree, core} = picked(in_form(""), &(&1.tag == ".form"))

      assert Inspector.form_names(core) == [
               {"id", "q-form"},
               {"as", ":q"},
               {"for", "assigns[:q_form]"},
               {"phx-change", nil},
               {"phx-submit", nil},
               {":let", "f"}
             ]

      assert ~w(id as for phx-change phx-submit :let phx-trigger-action action) --
               Inspector.form_panel_attrs() == []
    end
  end

  describe "a field's and a Send button's options inside a form" do
    setup %{chelekom: rows} do
      %{kit: rows ++ Factory.renamed_form_pair(rows)}
    end

    defp field_keys(source, kit, pick, opts \\ []) do
      {_tree, node} = picked(source, pick)
      node |> Inspector.field_controls(kit, opts) |> keys()
    end

    @plain ~w(debounce throttle field_autocomplete placeholder readonly disabled autofocus)

    test "a raw input and the CMS's own field forward every option, a kit field only its own", %{
      kit: kit
    } do
      raw = in_form(~s(<input id="phone" type="tel" name={f[:phone].name} />))

      kit_field =
        in_form(
          ~s(<.component component_name="chelekom-text-field" site="Global" id="nick" field={f[:nick]} />)
        )

      assert field_keys(raw, kit, &(&1.tag == "input")) == @plain
      assert field_keys(raw, kit, &(&1.tag == ".input")) == @plain

      assert field_keys(kit_field, kit, named("chelekom-text-field")) ==
               ~w(debounce throttle placeholder autofocus)
    end

    test "the three event bindings come only to someone who may write their code", %{kit: kit} do
      raw = in_form(~s(<input id="phone" type="tel" name={f[:phone].name} />))

      assert field_keys(raw, kit, &(&1.tag == "input"), code_allowed?: true) ==
               @plain ++ ~w(on_focus on_blur on_keyup)

      assert field_keys(raw, kit, &(&1.tag == "input"), code_allowed?: false) == @plain
    end

    test "autofill shows the default for the kind of field", %{kit: kit} do
      for {field, default} <- [
            {~s(<input id="x" type="tel" name={f[:p].name} />), "tel"},
            {~s(<input id="x" type="EMAIL" name={f[:e].name} />), "email"},
            {~s(<input id="x" name={f[:n].name} />), "on"},
            {~s(<.input id="x" field={f[:pw]} type="password" />), "current-password"}
          ] do
        {_tree, node} = picked(in_form(field), &(Tree.Node.attr_text(&1, "id") == "x"))

        assert Inspector.field_autofill(node, kit) == default, field

        assert %{placeholder: "Default: " <> ^default} =
                 node
                 |> Inspector.field_controls(kit)
                 |> Enum.find(&(&1.key == "field_autocomplete"))
      end
    end

    test "autofill says off when the form it is in turns it off", %{kit: kit} do
      source =
        String.replace(
          in_form(~s(<input id="x" type="email" name={f[:e].name} />)),
          ~s(id="q-form"),
          ~s(id="q-form" autocomplete="off")
        )

      {tree, node} = picked(source, &(Tree.Node.attr_text(&1, "id") == "x"))

      assert %{placeholder: "Default: off"} =
               node
               |> Inspector.field_controls(kit, form: Inspector.owning_form(tree, node))
               |> Enum.find(&(&1.key == "field_autocomplete"))

      {tree, on} =
        picked(
          in_form(~s(<input id="x" type="email" name={f[:e].name} />)),
          &(Tree.Node.attr_text(&1, "id") == "x")
        )

      assert %{placeholder: "Default: email"} =
               on
               |> Inspector.field_controls(kit, form: Inspector.owning_form(tree, on))
               |> Enum.find(&(&1.key == "field_autocomplete"))
    end

    test "check while typing shows As they type until another choice is written", %{kit: kit} do
      {_tree, node} = picked(in_form(~s(<input name={f[:p].name} />)), &(&1.tag == "input"))
      [debounce | _rest] = Inspector.field_controls(node, kit)

      assert Inspector.rule_value(node, debounce) == "300"
      assert %{kind: :set_attr, value: "blur"} = Inspector.rule_op(node, debounce, "blur")
      assert %{kind: :set_attr, value: "300"} = Inspector.rule_op(node, debounce, "300")
      assert %{kind: :delete_attr} = Inspector.rule_op(node, debounce, "")
    end

    test "a Send button: text while sending where forwarded, and a type only where it is written",
         %{
           kit: kit
         } do
      {_tree, send} = picked(in_form(card(~s(<button>Send</button>))), &(&1.tag == "button"))

      assert send |> Inspector.send_controls(kit, true, "type") |> keys() ==
               ~w(disable_with button_type)

      assert send |> Inspector.send_controls(kit, true, nil) |> keys() == ~w(disable_with)

      [text | _type] = Inspector.send_controls(send, kit, true, "type")
      refute text[:placeholder]
      assert text.help =~ "Empty keeps its own words."

      [_text, type] = Inspector.send_controls(send, kit, false, "type")
      assert type.shown == "button"
      assert Inspector.rule_value(send, type) == "button"
    end
  end

  # A RAW ELEMENT HAS NO BUNDLE TO ASK. `widget/3` reads a kit's declaration — the type, the values,
  # the `editor` hint — and an `<img>` somebody dropped on the page has none of it, so every
  # attribute in the Attributes list drew the same text box. The media library the editor already
  # ships was reachable from a component's `image_url` and from nowhere else.
  #
  # What a raw attribute does carry is the TAG, and that is what separates the two `src`.
  describe "element_widget/2" do
    test "a picture's source is a picture, chosen from the library" do
      assert Inspector.element_widget("img", "src") == :media
      assert Inspector.element_widget("video", "poster") == :media
      assert Inspector.element_widget("source", "srcset") == :media
    end

    # The name alone cannot tell these apart, which is the whole reason the tag is asked for.
    test "and a frame's source is an address, typed" do
      assert Inspector.element_widget("iframe", "src") == :url
      assert Inspector.element_widget("script", "src") == :url
    end

    test "a link is a link wherever it is written" do
      assert Inspector.element_widget("a", "href") == :url
      assert Inspector.element_widget("form", "action") == :url
      assert Inspector.element_widget("blockquote", "cite") == :url
    end

    test "and a colour gets a colour" do
      assert Inspector.element_widget("svg", "fill") == :color
      assert Inspector.element_widget("path", "stroke") == :color
    end

    test "anything this has no opinion about is a text box, not a guess" do
      assert Inspector.element_widget("div", "data-role") == :text
      assert Inspector.element_widget("div", "id") == :text
      assert Inspector.element_widget("input", "placeholder") == :text
      assert Inspector.element_widget(nil, "src") == :url
      assert Inspector.element_widget("img", nil) == :text
    end
  end

  # DECLARING A SLOT AND RENDERING ITS BODY ARE DIFFERENT THINGS. Nothing but the markup knows which
  # a slot is, so this reads the markup — and answers TRUE whenever it cannot tell, because a false
  # "nothing can go here" shuts an author out of a slot that does take content.
  describe "renders_slot?/2" do
    test "sees a slot rendered directly" do
      component = %{template: ~s|<figure>{render_slot(@caption)}</figure>|}
      assert Inspector.renders_slot?(component, "caption")
    end

    # Phoenix writes a multi-slot as a comprehension, which is the shape most of the kit uses.
    test "sees one rendered through a :for binding, destructured or not" do
      plain = %{template: ~s|<div :for={a <- @actions}>{render_slot(a)}</div>|}

      indexed = %{
        template: ~s|<li :for={{item, i} <- Enum.with_index(@item, 1)}>{render_slot(item)}</li>|
      }

      assert Inspector.renders_slot?(plain, "actions")
      assert Inspector.renders_slot?(indexed, "item")
    end

    # The case that started this: `chelekom-video` reads the slot's attributes and draws no body.
    test "says no when the slot is only ever read for its attributes" do
      component = %{
        template: ~s|<video><source :for={s <- @source} src={s.src} type={s.type} /></video>|
      }

      refute Inspector.renders_slot?(component, "source")
    end

    test "and follows a slot handed to a helper beside the template" do
      component = %{
        template: ~s|<div>{tail(@rest)}</div>|,
        helpers: [%{body: ~s|defp tail(list), do: Enum.map(list, &render_slot(&1))|}]
      }

      assert Inspector.renders_slot?(component, "rest"),
             "the binding is not one this can follow, so it must not claim otherwise"
    end

    test "inner_block is rendered by definition" do
      assert Inspector.renders_slot?(%{template: "<div></div>"}, "inner_block")
    end

    test "and anything it cannot read is treated as rendering" do
      assert Inspector.renders_slot?(%{}, "whatever")
      assert Inspector.renders_slot?(%{template: ""}, "whatever")
      assert Inspector.renders_slot?(%{template: nil}, "whatever")
      assert Inspector.renders_slot?(%{"template" => "<div></div>"}, nil)
    end

    test "reads a string-keyed component the same as an atom-keyed one" do
      atoms = %{template: ~s|<video><source :for={s <- @source} src={s.src} /></video>|}
      strings = %{"template" => ~s|<video><source :for={s <- @source} src={s.src} /></video>|}

      refute Inspector.renders_slot?(atoms, "source")
      refute Inspector.renders_slot?(strings, "source")
    end
  end

  # A SWITCH THE COMPONENT SUPPORTS AND THE PANEL COULD NOT SEE. A kit declares it through
  # `attr :rest, :global, include: ~w(animated)`, and two things drop it before the panel: the bundle
  # exporter does not carry an `include:` list, and `grouped/1` pulls `global` attributes out
  # entirely. So a skeleton had no way to be animated, and fifteen other components had switches
  # nobody could reach.
  describe "the @rest keys a component's own body reads" do
    test "are offered, and named after what the body consults" do
      skeleton = %{
        "attrs" => [%{"name" => "color", "type" => "string", "opts" => %{}}],
        "template" => ~S|<div class={["skeleton", @rest[:animated] && "animate-pulse"]}></div>|
      }

      assert [%{"name" => "animated", "type" => "boolean"}] = Inspector.rest_attrs(skeleton)
    end

    # WHAT THE COMPONENT ALREADY DECLARES WINS. Offering it twice puts two controls on one attribute.
    test "and a key the component declares properly is not offered again" do
      component = %{
        "attrs" => [%{"name" => "animated", "type" => "boolean", "opts" => %{}}],
        "template" => ~S|<div class={[@rest[:animated] && "x"]}></div>|
      }

      assert Inspector.rest_attrs(component) == []
    end

    # A VALUE IS ONE THAT REACHES THE PAGE, and the `&&` is not the tell — `cite` guards its own
    # value with one, `grouped` turns a class on with one.
    test "an attribute assigned straight from the key is a value, not a switch" do
      blockquote = %{
        "attrs" => [],
        "template" =>
          ~S|<blockquote :if={is_nil(@rest[:hide_icon])} cite={@rest[:cite] && @rest[:cite]}></blockquote>|
      }

      typed = Map.new(Inspector.rest_attrs(blockquote), &{&1["name"], &1["type"]})

      assert typed == %{"hide_icon" => "boolean", "cite" => "string"}
    end

    # `:if=` WEARS AN ATTRIBUTE'S SHAPE and is a condition, so it must not read as a value.
    test "a key used only as a condition is a switch" do
      pagination = %{
        "attrs" => [],
        "template" => ~S|<nav><span :if={@rest[:show_edges]}>x</span></nav>|
      }

      assert [%{"name" => "show_edges", "type" => "boolean"}] = Inspector.rest_attrs(pagination)
    end

    # HTML'S OWN BOOLEANS ARE BOOLEAN WHEREVER THEY LAND. A field writes `disabled={@rest[:disabled]}`
    # — an assignment by the rule above, and a switch by every other measure.
    test "an HTML boolean attribute stays a switch even when assigned" do
      input = %{"attrs" => [], "template" => ~S|<input disabled={@rest[:disabled]} />|}

      assert [%{"name" => "disabled", "type" => "boolean"}] = Inspector.rest_attrs(input)
    end

    test "a component whose body reads nothing out of rest offers nothing" do
      assert Inspector.rest_attrs(%{"attrs" => [], "template" => ~S|<div {@rest}></div>|}) == []
    end

    # AND THEY LAND IN THE RIGHT SECTION, which is what makes them findable rather than merely
    # present — `animated` belongs with the other behaviour switches.
    test "and are grouped like any other attribute" do
      skeleton = %{
        "attrs" => [%{"name" => "color", "type" => "string", "opts" => %{}}],
        "template" => ~S|<div class={[@rest[:animated] && "animate-pulse"]}></div>|
      }

      groups =
        Map.new(Inspector.grouped(skeleton), fn {g, as} ->
          {g, Enum.map(as, &Inspector.name/1)}
        end)

      assert "animated" in Map.get(groups, "Behavior", [])
    end
  end
end
