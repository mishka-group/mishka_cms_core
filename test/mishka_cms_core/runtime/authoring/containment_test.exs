# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.ContainmentTest do
  @moduledoc """
  The drop rules. Every case the React `containment.js` suite asserted is here, plus the pairwise
  content-model rules it never had — a `<ul>` that only takes `<li>`, a `<tr>` that only takes cells
  — and the slot rules for components.

  These run on the server, which is the point: the browser hint can be wrong or tampered with, and
  the answer that decides whether the tree mutates is this one.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.Containment
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node
  alias MishkaCmsCore.Test.Factory

  # The real Chelekom form rows, and a renamed pair only their markup marks as forms.
  setup_all do
    rows = Factory.chelekom_rows(~w(chelekom-card chelekom-form-wrapper chelekom-simple-form))

    {:ok, kit: rows ++ Factory.renamed_form_pair(rows)}
  end

  defp tree_of(heex), do: Tree.parse!(heex)
  defp find(tree, tag), do: Enum.find(Tree.walk(tree), &(&1.tag == tag))
  defp block, do: Node.new(:tag, tag: "div")
  defp inline, do: Node.new(:tag, tag: "span")
  defp text, do: Node.new(:text, text: "hello")

  describe "accepts_children?/1 — ported from containment.js" do
    test "void elements reject children" do
      for tag <- Containment.void_tags() do
        refute Containment.accepts_children?(tag), "#{tag} should be void"
      end
    end

    test "phrasing-only elements can still hold children — just not block ones" do
      for tag <- ~w(a span p h1 button pre label code) do
        assert Containment.accepts_children?(tag)
        assert Containment.phrasing_only?(tag)
      end
    end

    test "flow containers are not phrasing-only" do
      for tag <- ~w(div section article li td) do
        refute Containment.phrasing_only?(tag)
      end
    end

    test "flow containers accept children" do
      for tag <- ~w(div section article main aside nav form li td) do
        assert Containment.accepts_children?(tag)
      end
    end

    test "components and slots are permissive at this level" do
      assert Containment.accepts_children?(".card")
      assert Containment.accepts_children?(":item")
      assert Containment.accepts_children?(nil)
    end

    test "the check is case-insensitive" do
      refute Containment.accepts_children?("BR")
      refute Containment.accepts_children?("IMG")
    end
  end

  describe "can_drop?/4 — roots and voids" do
    test "the root always accepts" do
      assert Containment.can_drop?(tree_of("<div></div>"), block(), :root) == :ok
    end

    test "a void element refuses everything" do
      tree = tree_of(~s(<img src="a.png">))
      img = find(tree, "img")

      assert {:error, message} = Containment.can_drop?(tree, block(), img.id)
      assert message =~ "cannot contain"
      assert {:error, _msg} = Containment.can_drop?(tree, text(), img.id)
    end

    test "a text node is never a drop target" do
      tree = tree_of("<p>words</p>")
      node = Enum.find(Tree.walk(tree), &(&1.kind == :text))

      assert {:error, message} = Containment.can_drop?(tree, block(), node.id)
      assert message =~ "text only"
    end

    test "a missing target is refused rather than crashing" do
      assert {:error, message} =
               Containment.can_drop?(tree_of("<div></div>"), block(), "nzzzzzzzz")

      assert message =~ "no longer exists"
    end
  end

  describe "can_drop?/4 — phrasing content" do
    test "a phrasing-only element refuses a block child" do
      tree = tree_of("<span></span>")
      span = find(tree, "span")

      assert {:error, message} = Containment.can_drop?(tree, block(), span.id)
      assert message =~ "text and inline"
    end

    test "a phrasing-only element accepts text" do
      tree = tree_of("<span></span>")
      span = find(tree, "span")

      assert Containment.can_drop?(tree, text(), span.id) == :ok
    end

    test "a heading accepts an inline element" do
      tree = tree_of("<h1></h1>")
      h1 = find(tree, "h1")

      assert Containment.can_drop?(tree, inline(), h1.id) == :ok
    end

    test "a paragraph refuses a nested div" do
      tree = tree_of("<p></p>")
      p = find(tree, "p")

      assert {:error, _message} = Containment.can_drop?(tree, block(), p.id)
    end
  end

  describe "can_drop?/4 — pairwise structural rules" do
    test "a list accepts only list items" do
      tree = tree_of("<ul></ul>")
      ul = find(tree, "ul")

      assert Containment.can_drop?(tree, Node.new(:tag, tag: "li"), ul.id) == :ok
      assert {:error, message} = Containment.can_drop?(tree, block(), ul.id)
      assert message =~ "`<li>`"
    end

    test "an ordered list behaves like an unordered one" do
      tree = tree_of("<ol></ol>")
      ol = find(tree, "ol")

      assert Containment.can_drop?(tree, Node.new(:tag, tag: "li"), ol.id) == :ok
      assert {:error, _message} = Containment.can_drop?(tree, Node.new(:tag, tag: "p"), ol.id)
    end

    test "a table row accepts only cells" do
      tree = tree_of("<table><tr></tr></table>")
      tr = find(tree, "tr")

      assert Containment.can_drop?(tree, Node.new(:tag, tag: "td"), tr.id) == :ok
      assert Containment.can_drop?(tree, Node.new(:tag, tag: "th"), tr.id) == :ok
      assert {:error, _message} = Containment.can_drop?(tree, block(), tr.id)
    end

    test "a table body accepts only rows" do
      tree = tree_of("<table><tbody></tbody></table>")
      tbody = find(tree, "tbody")

      assert Containment.can_drop?(tree, Node.new(:tag, tag: "tr"), tbody.id) == :ok
      assert {:error, _message} = Containment.can_drop?(tree, Node.new(:tag, tag: "td"), tbody.id)
    end

    test "a select accepts only options and groups" do
      tree = tree_of("<select></select>")
      select = find(tree, "select")

      assert Containment.can_drop?(tree, Node.new(:tag, tag: "option"), select.id) == :ok
      assert Containment.can_drop?(tree, Node.new(:tag, tag: "optgroup"), select.id) == :ok
      assert {:error, _message} = Containment.can_drop?(tree, block(), select.id)
    end

    test "a definition list accepts terms, descriptions and wrappers" do
      tree = tree_of("<dl></dl>")
      dl = find(tree, "dl")

      for tag <- ~w(dt dd div) do
        assert Containment.can_drop?(tree, Node.new(:tag, tag: tag), dl.id) == :ok
      end

      assert {:error, _message} = Containment.can_drop?(tree, Node.new(:tag, tag: "p"), dl.id)
    end

    test "a structural parent still accepts text and expressions" do
      tree = tree_of("<tr></tr>")
      tr = find(tree, "tr")

      assert Containment.can_drop?(tree, text(), tr.id) == :ok
      assert Containment.can_drop?(tree, Node.new(:eex, text: "@cell"), tr.id) == :ok
    end

    test "a component is opaque and passes a structural gate" do
      tree = tree_of("<ul></ul>")
      ul = find(tree, "ul")

      assert Containment.can_drop?(tree, Node.new(:component, tag: ".row"), ul.id) == :ok
    end
  end

  describe "can_drop?/4 — interactive nesting" do
    test "an anchor refuses another clickable element" do
      tree = tree_of(~s(<a href="#"></a>))
      a = find(tree, "a")

      assert {:error, message} = Containment.can_drop?(tree, Node.new(:tag, tag: "button"), a.id)
      assert message =~ "clickable"
    end

    test "an anchor refuses an inline subtree that merely contains a clickable element" do
      tree = tree_of(~s(<a href="#"></a><span><button>x</button></span>))
      a = find(tree, "a")
      span = find(tree, "span")

      assert {:error, message} = Containment.can_drop?(tree, span, a.id)
      assert message =~ "clickable"
    end

    test "a block subtree is refused by the phrasing rule before the interactive one" do
      tree = tree_of(~s(<a href="#"></a><section><button>x</button></section>))
      a = find(tree, "a")
      section = find(tree, "section")

      assert {:error, message} = Containment.can_drop?(tree, section, a.id)
      assert message =~ "text and inline"
    end

    test "an anchor accepts a subtree with no clickable descendant" do
      tree = tree_of(~s(<a href="#"></a><span><em>x</em></span>))
      a = find(tree, "a")
      span = find(tree, "span")

      assert Containment.can_drop?(tree, span, a.id) == :ok
    end

    test "an anchor accepts plain inline content" do
      tree = tree_of(~s(<a href="#"></a>))
      a = find(tree, "a")

      assert Containment.can_drop?(tree, text(), a.id) == :ok
      assert Containment.can_drop?(tree, inline(), a.id) == :ok
    end
  end

  describe "can_drop?/4 — components and slots" do
    test "a component with declared slots accepts a child" do
      tree = tree_of(~s(<.card />))
      card = find(tree, ".card")
      meta = [%{name: "card", slots: [%{name: "inner_block"}]}]

      assert Containment.can_drop?(tree, block(), card.id, components: meta) == :ok
    end

    test "a component with no declared slots refuses a child" do
      tree = tree_of(~s(<.card />))
      card = find(tree, ".card")
      meta = [%{name: "card", slots: []}]

      assert {:error, message} = Containment.can_drop?(tree, block(), card.id, components: meta)
      assert message =~ "does not declare a slot"
    end

    test "a component that already holds children accepts more" do
      tree = tree_of(~s(<.card>existing</.card>))
      card = find(tree, ".card")

      assert Containment.can_drop?(tree, block(), card.id, components: []) == :ok
    end

    test "metadata with string keys is understood too" do
      tree = tree_of(~s(<.card />))
      card = find(tree, ".card")
      meta = [%{"name" => "card", "slots" => [%{"name" => "inner_block"}]}]

      assert Containment.can_drop?(tree, block(), card.id, components: meta) == :ok
    end

    test "a slot always accepts content" do
      tree = tree_of(~s(<.card><:item /></.card>))
      slot = find(tree, ":item")

      assert Containment.can_drop?(tree, block(), slot.id) == :ok
    end

    test "an unknown component with no children and no metadata is refused" do
      tree = tree_of(~s(<.mystery />))
      mystery = find(tree, ".mystery")

      assert {:error, _message} = Containment.can_drop?(tree, block(), mystery.id, components: [])
    end
  end

  # WHAT THE LAYERS RAIL ASKS WHILE IT RENDERS A ROW, before anything has been picked up. It used to
  # answer this itself, in `Panels.drop_target?/2`, and its reading was strictly narrower than the one
  # below: a component needed a PALETTE ROW to count as a container. So the `<.form>` this editor
  # wraps every loose field in — declared by Phoenix, shipped by no kit — was drawn as a row nothing
  # could be dropped inside, and a field aimed at the middle of it was pushed out beside it instead.
  #
  # These are the three cases where the two used to disagree, plus the two where they always agreed.
  describe "holds_children?/2 — the rail's question" do
    test "a component with no palette row still holds children when Phoenix declares its slot" do
      tree = tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}></.form>))

      assert Containment.holds_children?(find(tree, ".form"), components: [])
    end

    test "a component with no palette row holds children once something is in it" do
      tree = tree_of(~s(<.mystery>existing</.mystery>))

      assert Containment.holds_children?(find(tree, ".mystery"), components: [])
    end

    test "and a slot always holds children, which is what a slot is" do
      tree = tree_of(~s(<.card><:item /></.card>))

      assert Containment.holds_children?(find(tree, ":item"), components: [])
    end

    test "an empty component nothing declares a slot for does not" do
      tree = tree_of(~s(<.mystery />))

      refute Containment.holds_children?(find(tree, ".mystery"), components: [])
    end

    test "nor does a void tag, or anything that is not an element at all" do
      tree = tree_of(~s(<div><img src="a.png" />text</div>))

      assert Containment.holds_children?(find(tree, "div"))
      refute Containment.holds_children?(find(tree, "img"))
      refute Containment.holds_children?(Node.new(:text, text: "hello"))
      refute Containment.holds_children?(nil)
    end
  end

  describe "can_drop?/4 — a CMS-local function component" do
    test "an empty <.form> takes a child, because Phoenix declares its slot" do
      tree = tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}></.form>))
      form = find(tree, ".form")

      assert Containment.can_drop?(tree, Node.new(:tag, tag: "input"), form.id, components: []) ==
               :ok
    end

    test "a dotted tag no module declares is still refused" do
      tree = tree_of(~s(<.mystery />))
      mystery = find(tree, ".mystery")

      assert {:error, _message} = Containment.can_drop?(tree, block(), mystery.id, components: [])
    end
  end

  describe "can_drop?/4 — forms" do
    test "a form refuses to go inside a form" do
      tree = tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}></.form>))
      form = find(tree, ".form")
      dragged = Node.new(:component, tag: ".form")

      assert {:error, message} = Containment.can_drop?(tree, dragged, form.id, components: [])
      assert message =~ "inside another form"
    end

    test "and refuses anywhere below one" do
      tree =
        tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>))

      row = find(tree, "div")

      assert {:error, _message} =
               Containment.can_drop?(tree, Node.new(:tag, tag: "form"), row.id, components: [])
    end

    test "a raw <form> element counts on both sides" do
      tree = tree_of(~s(<form><div id="row"></div></form>))
      row = find(tree, "div")

      assert {:error, _message} = Containment.can_drop?(tree, Node.new(:tag, tag: "form"), row.id)
    end

    test "a node is a form because it names a page assign, whatever it is called" do
      tree =
        tree_of(
          ~s(<.component component_name="kit-form" for={assigns[:q_form]}><div id="row"></div></.component>)
        )

      row = find(tree, "div")
      dragged = Node.new(:component, tag: ".form")

      assert {:error, _message} = Containment.can_drop?(tree, dragged, row.id, components: [])
    end

    test "a form is welcome beside another form" do
      tree =
        tree_of(~s(<div id="page"><.form :let={f} as={:q} for={assigns[:q_form]}></.form></div>))

      page = find(tree, "div")

      assert Containment.can_drop?(tree, Node.new(:component, tag: ".form"), page.id) == :ok
    end

    test "a field is welcome inside one" do
      tree =
        tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>))

      row = find(tree, "div")

      assert Containment.can_drop?(tree, Node.new(:tag, tag: "input"), row.id) == :ok
    end
  end

  # THIS MODULE USED TO ANSWER "is this a form" ON ITS OWN, and its answer was the narrowest of the
  # four in the editor: the tag, plus a `for=` naming a page assign. A kit's form wrapper is neither
  # — it is a `.component` node whose seeded `for` is `{%{}}` — so the drop this rule exists to
  # refuse went through, and the audit rail reported the nesting afterwards instead. It asks
  # `Fields.form_node?/2` now, which is what `FormPlacement` and `FormChecks` already asked.
  describe "can_drop?/4 — a form is whatever the kit says a form is" do
    @wrapper %{
      name: "kit-form",
      slots: [%{"name" => "inner_block"}],
      attrs: [%{"name" => "for", "type" => "any"}],
      template: ~S(<.form :let={f} for={@for}><div class="wrapper-form"></div></.form>)
    }

    defp wrapper_node do
      Node.new(:component,
        tag: ".component",
        attrs: [{"component_name", {:string, "kit-form"}}, {"for", {:expr, "%{}"}}]
      )
    end

    test "a kit wrapper refuses to go inside Phoenix's own form" do
      tree =
        tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>))

      row = find(tree, "div")

      assert {:error, message} =
               Containment.can_drop?(tree, wrapper_node(), row.id, components: [@wrapper])

      assert message =~ "inside another form"
    end

    test "and a form refuses to go inside a kit wrapper already on the canvas" do
      tree =
        tree_of(
          ~s(<.component component_name="kit-form" site="Global" for={%{}}><div id="row"></div></.component>)
        )

      row = find(tree, "div")

      assert {:error, _message} =
               Containment.can_drop?(tree, Node.new(:tag, tag: "form"), row.id,
                 components: [@wrapper]
               )
    end

    test "one kit wrapper refuses to go inside another" do
      tree =
        tree_of(
          ~s(<.component component_name="kit-form" site="Global" for={%{}}><div id="row"></div></.component>)
        )

      row = find(tree, "div")

      assert {:error, _message} =
               Containment.can_drop?(tree, wrapper_node(), row.id, components: [@wrapper])
    end

    test "a kit component that is not a wrapper is still welcome inside a form" do
      tree =
        tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>))

      row = find(tree, "div")

      field = %{
        name: "kit-text",
        attrs: [
          %{"name" => "field", "type" => "struct", "struct_name" => "Phoenix.HTML.FormField"}
        ],
        template: ~S(<input name={@name} />)
      }

      dragged =
        Node.new(:component,
          tag: ".component",
          attrs: [{"component_name", {:string, "kit-text"}}]
        )

      assert Containment.can_drop?(tree, dragged, row.id, components: [field]) == :ok
    end

    # A BLOCK IS ITS OWN SUBTREE, and every form block opens with a band tag by design — so the head
    # node that arrives is a `<section>` and its `<.form>` is a child, in the PARSED TEMPLATE rather
    # than in the document. Read the head alone and the block nests two forms silently.
    test "a block whose head is a band still brings the form inside it" do
      tree =
        tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>))

      row = find(tree, "div")

      block =
        tree_of(
          ~s(<section><.form :let={g} as={:c} for={assigns[:c_form]}><input name="e" /></.form></section>)
        )

      head = Tree.get(block, hd(block.roots))

      assert {:error, message} =
               Containment.can_drop?(tree, head, row.id, dragged_tree: block, components: [])

      assert message =~ "inside another form"
    end

    test "and a block that brings no form is welcome" do
      tree =
        tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>))

      row = find(tree, "div")
      block = tree_of(~s(<section><h2>Heading</h2><input name="e" /></section>))
      head = Tree.get(block, hd(block.roots))

      assert Containment.can_drop?(tree, head, row.id, dragged_tree: block, components: []) == :ok
    end

    test "moving a section that holds a form into a form is refused too" do
      tree =
        tree_of(
          ~s(<div id="page"><.form :let={f} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>) <>
            ~s(<section id="band"><.form :let={g} as={:c} for={assigns[:c_form]}></.form></section></div>)
        )

      row = Enum.find(Tree.walk(tree), &(Node.attr_text(&1, "id") == "row"))
      band = Enum.find(Tree.walk(tree), &(&1.tag == "section"))

      assert {:error, _message} = Containment.can_drop?(tree, band, row.id, components: [])
    end

    test "accepts_map/3 refuses every node under a form for a kit wrapper" do
      tree =
        tree_of(~s(<.form :let={f} as={:q} for={assigns[:q_form]}><div id="row"></div></.form>))

      row = find(tree, "div")
      form = find(tree, ".form")

      hints = Containment.accepts_map(tree, wrapper_node(), components: [@wrapper])

      refute hints[row.id]
      refute hints[form.id]
    end
  end

  # A kit field that declares slots reads as a container, and a field dropped onto it landed inside it,
  # where no slot draws it.
  describe "can_drop?/4 — a field does not hold another field" do
    @kit_field %{
      name: "kit-text",
      slots: [%{"name" => "start_section"}, %{"name" => "end_section"}],
      attrs: [
        %{"name" => "field", "type" => "struct", "struct_name" => "Phoenix.HTML.FormField"},
        %{"name" => "label", "type" => "string"}
      ],
      template: ~S(<div><input name={@field.name} value={@field.value} /></div>)
    }

    defp kit_field_node(key) do
      Node.new(:component,
        tag: ".component",
        attrs: [{"component_name", {:string, "kit-text"}}, {"field", {:expr, "f[:#{key}]"}}]
      )
    end

    defp deep_form(inner),
      do:
        ~s(<.form :let={f} as={:q} for={assigns[:q_form]}><div class="card"><div class="grid"><div class="col">) <>
          inner <> ~s(</div></div></div></.form>)

    test "a kit field refuses a kit field dropped into it, deep in a form's card" do
      tree =
        tree_of(
          deep_form(~s(<.component component_name="kit-text" site="Global" field={f[:name]} />))
        )

      target = Enum.find(Tree.walk(tree), &(Node.component_name(&1) == "kit-text"))

      assert {:error, message} =
               Containment.can_drop?(tree, kit_field_node("email"), target.id,
                 components: [@kit_field]
               )

      assert message =~ "inside another field"
    end

    test "and refuses a raw input the same way" do
      tree =
        tree_of(
          deep_form(~s(<.component component_name="kit-text" site="Global" field={f[:name]} />))
        )

      target = Enum.find(Tree.walk(tree), &(Node.component_name(&1) == "kit-text"))

      assert {:error, _message} =
               Containment.can_drop?(tree, Node.new(:tag, tag: "input"), target.id,
                 components: [@kit_field]
               )
    end

    test "a kit field still takes what is not a field, and the column beside it still takes a field" do
      tree =
        tree_of(
          deep_form(~s(<.component component_name="kit-text" site="Global" field={f[:name]} />))
        )

      target = Enum.find(Tree.walk(tree), &(Node.component_name(&1) == "kit-text"))
      column = Enum.find(Tree.walk(tree), &(Node.attr_text(&1, "class") == "col"))

      assert :ok = Containment.can_drop?(tree, inline(), target.id, components: [@kit_field])

      assert :ok =
               Containment.can_drop?(tree, kit_field_node("email"), column.id,
                 components: [@kit_field]
               )
    end

    test "a select still takes its options" do
      tree = tree_of(deep_form(~s(<select name="pick"></select>)))

      assert :ok =
               Containment.can_drop?(tree, Node.new(:tag, tag: "option"), find(tree, "select").id,
                 components: []
               )
    end
  end

  # CARD > GRID > COLUMN is where a real page puts a form's fields and its Send button, three levels
  # under the form's edge. A second form dropped there is still inside the first one.
  describe "can_drop?/4 — a form deep inside another form's card" do
    defp card(inner),
      do:
        ~s(<.component component_name="chelekom-card" site="Global" padding="large">) <>
          ~s(<div id="grid" class="grid grid-cols-2 gap-4"><div id="col" class="col-span-1">) <>
          inner <> "</div></div></.component>"

    defp by_id(tree, id), do: Enum.find(Tree.walk(tree), &(Node.attr_text(&1, "id") == id))

    defp kit_form(name),
      do:
        Node.new(:component,
          tag: ".component",
          attrs: [{"component_name", {:string, name}}, {"site", {:string, "Global"}}]
        )

    defp phoenix_page,
      do:
        tree_of(
          ~s(<div id="page"><.form :let={f} as={:q} for={assigns[:q_form]}>) <>
            card(~s(<input name={f[:email].name} />)) <> "</.form></div>"
        )

    defp kit_page(name),
      do:
        tree_of(
          ~s(<div id="page"><.component component_name="#{name}" site="Global" :let={f}>) <>
            card(~s(<input name={f[:email].name} />)) <> "</.component></div>"
        )

    test "every kind of form is refused in the column of a Phoenix form's card", %{kit: kit} do
      tree = phoenix_page()
      column = by_id(tree, "col")

      for name <- ~w(chelekom-form-wrapper chelekom-simple-form acme-wrapper acme-simple) do
        assert {:error, message} =
                 Containment.can_drop?(tree, kit_form(name), column.id, components: kit),
               name

        assert message =~ "inside another form"

        assert Containment.can_drop?(tree, kit_form(name), by_id(tree, "page").id,
                 components: kit
               ) == :ok,
               "#{name} is welcome beside the form"
      end
    end

    test "and a form is refused in the column of a kit form's card, however it is named", %{
      kit: kit
    } do
      for name <- ~w(chelekom-form-wrapper acme-wrapper acme-simple) do
        tree = kit_page(name)
        column = by_id(tree, "col")

        for dragged <- [
              Node.new(:component, tag: ".form"),
              Node.new(:tag, tag: "form"),
              kit_form("acme-simple")
            ] do
          assert {:error, _message} =
                   Containment.can_drop?(tree, dragged, column.id, components: kit),
                 "#{inspect(dragged.tag)} inside #{name}"
        end

        assert Containment.can_drop?(tree, Node.new(:tag, tag: "input"), column.id,
                 components: kit
               ) == :ok

        assert Containment.can_drop?(tree, Node.new(:component, tag: ".button"), column.id,
                 components: kit
               ) == :ok
      end
    end

    test "accepts_map/3 refuses the card, the grid and the column for a renamed Simple Form", %{
      kit: kit
    } do
      tree = phoenix_page()
      hints = Containment.accepts_map(tree, kit_form("acme-simple"), components: kit)
      card = Enum.find(Tree.walk(tree), &(Node.component_name(&1) == "chelekom-card"))

      for id <- [card.id, by_id(tree, "grid").id, by_id(tree, "col").id] do
        refute hints[id]
      end

      assert hints[by_id(tree, "page").id]
    end
  end

  describe "can_drop?/4 — cycles" do
    test "a node refuses to be dropped into itself" do
      tree = tree_of("<div></div>")
      div = find(tree, "div")

      assert {:error, message} = Containment.can_drop?(tree, div, div.id)
      assert message =~ "inside itself"
    end

    test "a node refuses to be dropped into its own descendant" do
      tree = tree_of(~s(<div id="outer"><section id="inner"></section></div>))
      outer = find(tree, "div")
      inner = find(tree, "section")

      assert {:error, _message} = Containment.can_drop?(tree, outer, inner.id)
    end

    test "a sibling is a legal target" do
      tree = tree_of(~s(<div><section></section><article></article></div>))
      section = find(tree, "section")
      article = find(tree, "article")

      assert Containment.can_drop?(tree, section, article.id) == :ok
    end
  end

  describe "accepts_map/3" do
    test "answers for every node in the tree" do
      tree = tree_of(~s(<div><span></span><img src="a.png"><section></section></div>))
      map = Containment.accepts_map(tree, block())

      assert map_size(map) == Tree.size(tree)
      assert map[find(tree, "div").id] == true
      assert map[find(tree, "section").id] == true
      assert map[find(tree, "span").id] == false
      assert map[find(tree, "img").id] == false
    end

    test "the hint agrees with can_drop? for every node" do
      tree = tree_of(~s(<ul><li></li></ul><table><tr></tr></table><p></p>))
      dragged = block()
      map = Containment.accepts_map(tree, dragged)

      for {id, hint} <- map do
        assert hint == (Containment.can_drop?(tree, dragged, id) == :ok)
      end
    end
  end

  # DECLARING A SLOT AND RENDERING ITS BODY ARE DIFFERENT THINGS, and thirteen of the kit's slots do
  # only the first. `chelekom-video` declares `:source` and its markup is
  # `<source :for={s <- @source} src={s.src} type={s.type} />` — it reads the slot's ATTRIBUTES and
  # never calls `render_slot`. Every surface used to say yes to a drop into one: the rail drew it as
  # a container, the map offered it, the drop landed, the tree kept it, and the canvas drew nothing.
  describe "a slot the component never renders" do
    defp video do
      %{
        name: "vid",
        template: ~s|<video><source :for={s <- @source} src={s.src} type={s.type} /></video>|,
        slots: [%{"name" => "source", "opts" => %{}, "attrs" => []}]
      }
    end

    defp captioned do
      %{
        name: "quote",
        template:
          ~s|<figure>{render_slot(@inner_block)}<figcaption>{render_slot(@caption)}</figcaption></figure>|,
        slots: [%{"name" => "caption", "opts" => %{}, "attrs" => []}]
      }
    end

    defp listed do
      %{
        name: "acc",
        template:
          ~s|<div><section :for={{item, i} <- Enum.with_index(@item, 1)}>{render_slot(item)}</section></div>|,
        slots: [%{"name" => "item", "opts" => %{}, "attrs" => []}]
      }
    end

    defp slot_in(heex, _name, entry) do
      tree = tree_of(heex)
      slot = Enum.find(Tree.walk(tree), &(&1.kind == :slot))
      {tree, slot, [components: [entry]]}
    end

    test "takes nothing, however it is asked" do
      {tree, slot, opts} =
        slot_in(
          ~s|<.component component_name="vid"><:source src="a" type="b" /></.component>|,
          "source",
          video()
        )

      refute Containment.holds_children?(slot, opts)
      assert {:error, message} = Containment.can_drop?(tree, block(), slot.id, opts)
      assert message =~ "set by its properties"
    end

    # Not even when something is already in it: whatever is in there is not being drawn either, so
    # letting a second thing follow it only makes the disagreement bigger.
    test "is refused even once something has been put in it" do
      {tree, slot, opts} =
        slot_in(
          ~s|<.component component_name="vid"><:source src="a" type="b"><span>x</span></:source></.component>|,
          "source",
          video()
        )

      assert slot.children != []
      refute Containment.holds_children?(slot, opts)
      assert {:error, _refused} = Containment.can_drop?(tree, block(), slot.id, opts)
    end

    test "while a slot the component DOES render still takes content" do
      {tree, slot, opts} =
        slot_in(
          ~s|<.component component_name="quote"><:caption>hi</:caption></.component>|,
          "caption",
          captioned()
        )

      assert Containment.holds_children?(slot, opts)
      assert Containment.can_drop?(tree, inline(), slot.id, opts) == :ok
    end

    # Phoenix writes a multi-slot as a comprehension, which is the shape most of the kit uses.
    test "and so does one rendered through a :for binding" do
      {tree, slot, opts} =
        slot_in(
          ~s|<.component component_name="acc"><:item>hi</:item></.component>|,
          "item",
          listed()
        )

      assert Containment.holds_children?(slot, opts)
      assert Containment.can_drop?(tree, block(), slot.id, opts) == :ok
    end

    # EVERY PATH THAT CANNOT ANSWER SAYS YES. A false "nothing can go here" shuts an author out of a
    # slot that does take content, which is worse than the silence this is ending.
    test "and anything unresolvable is let through" do
      heex = ~s|<.component component_name="vid"><:source src="a" /></.component>|
      tree = tree_of(heex)
      slot = Enum.find(Tree.walk(tree), &(&1.kind == :slot))

      assert Containment.holds_children?(slot, components: []), "no metadata at all"

      assert Containment.holds_children?(slot, components: [%{name: "vid", slots: []}]),
             "an entry that declares no such slot"

      assert Containment.holds_children?(slot,
               components: [%{name: "vid", template: "", slots: [%{"name" => "source"}]}]
             ),
             "an entry with no markup stored"
    end
  end
end
