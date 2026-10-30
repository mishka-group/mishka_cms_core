# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.ElementsTest do
  @moduledoc """
  The structural elements, and the two properties that decide whether they are usable.

  Every entry has to PARSE — an element whose template the tree refuses is a card that does nothing
  when pressed — and the containers have to arrive EMPTY, because arriving empty is the whole point
  of them. The text elements are the deliberate exception, and so is the form.

  The Forms group has a rule of its own. A form ships FILLED, because the five attributes that make
  it a form are the thing it teaches and an empty one teaches none of them; the bare controls beside
  it ship with a literal `name`, because a palette card and a hover preview render them on their own,
  outside any form.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.{Containment, Elements, PageForms, Tree}
  alias MishkaCmsCore.Runtime.Authoring.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node

  test "every element's template parses into a tree" do
    for element <- Elements.all() do
      assert {:ok, tree} = Tree.parse(element.template),
             "#{element.id} does not parse: #{element.template}"

      assert Tree.size(tree) > 0, "#{element.id} parses to nothing"
    end
  end

  test "ids are unique and namespaced away from blocks" do
    ids = Enum.map(Elements.all(), & &1.id)

    assert ids == Enum.uniq(ids)
    assert Enum.all?(ids, &String.starts_with?(&1, "el-"))
  end

  # A LAYOUT ELEMENT IS A HOLE TO PUT THINGS IN. If one shipped with content, dropping a Section
  # would give you a Section with somebody else's words in it — that is what the Blocks library is
  # for, and the two must not blur.
  test "layout containers arrive empty" do
    for element <- Enum.filter(Elements.all(), &(&1.category == "Layout")) do
      {:ok, tree} = Tree.parse(element.template)

      leaves =
        tree
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :text and String.trim(&1.text || "") != ""))

      assert leaves == [], "#{element.id} ships with text in it"
    end
  end

  # AND A TEXT ELEMENT IS ITS TEXT. An empty `<p>` is invisible and has no sensible empty state, so
  # these say what they are and the author types over them.
  test "text elements arrive with words in them" do
    for element <- Enum.filter(Elements.all(), &(&1.category == "Text")) do
      {:ok, tree} = Tree.parse(element.template)

      text =
        tree
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :text))
        |> Enum.map_join(" ", &(&1.text || ""))
        |> String.trim()

      assert text != "", "#{element.id} would render as nothing"
    end
  end

  # The canvas outlines any childless container while editing. An element that is BOTH a container
  # and empty relies on that; one that is a void tag must not get it, or every divider on the page
  # grows a dashed box.
  test "the divider and the image are void tags, so nothing outlines them" do
    for id <- ~w(el-divider el-image) do
      {:ok, tree} = Tree.parse(Elements.get(id).template)
      node = tree |> Tree.walk() |> Enum.find(&(&1.kind == :tag))

      refute Containment.accepts_children?(node.tag),
             "#{id} renders <#{node.tag}>, which the canvas would outline as an empty box"
    end
  end

  test "the column grids arrive with the right number of empty cells" do
    for {id, count} <- [{"el-columns-2", 2}, {"el-columns-3", 3}, {"el-columns-4", 4}] do
      {:ok, tree} = Tree.parse(Elements.get(id).template)
      [root] = tree.roots
      assert length(Tree.get(tree, root).children) == count
    end
  end

  describe "search/1" do
    test "no query means everything" do
      assert length(Elements.search(nil)) == length(Elements.all())
      assert length(Elements.search("")) == length(Elements.all())
    end

    test "finds by title" do
      ids = Elements.search("column") |> Enum.map(& &1.id)
      assert "el-columns-2" in ids
      assert "el-columns-4" in ids
    end

    # An author looks for what a thing DOES, not what the tag is called — `aside` is the one nobody
    # searches for by name.
    test "finds by description" do
      assert Elements.search("sidebar") |> Enum.map(& &1.id) == ["el-aside"]
    end

    test "an unmatched query is empty, not everything" do
      assert Elements.search("zzzz-nothing") == []
    end
  end

  test "categories are listed in declaration order" do
    assert Elements.categories() == ["Layout", "Text", "Media", "Forms", "Dynamic"]
  end

  describe "the Forms group" do
    test "offers every part of a form" do
      ids = Elements.all() |> Enum.filter(&(&1.category == "Forms")) |> Enum.map(& &1.id)

      assert ids ==
               ~w(el-form el-fieldset el-label el-input el-textarea el-select el-checkbox
                  el-radio-group el-submit)
    end

    test "the form is a real one, with all five names derived from one seed" do
      [spec] = PageForms.declared(Elements.get("el-form").template)

      assert spec.as == "form"
      assert spec.assign == :form_form
      assert spec.id == "form"
      assert spec.change == "form_validate"
      assert spec.submit == "form_submit"
    end

    # SHIPPING IT EMPTY IS A DEAD END. A form with nothing in it cannot be dropped into until it
    # renders, and the field and the button are what show an author what goes where.
    test "the form arrives with a bound field and a submit button in it" do
      [spec] = PageForms.declared(Elements.get("el-form").template)
      {:ok, tree} = Tree.parse(Elements.get("el-form").template)

      assert Enum.map(spec.fields, & &1.key) == [:field]

      assert Enum.any?(Tree.walk(tree), fn node ->
               node.tag == "button" and
                 Node.attr_text(node, "type") == "submit"
             end)
    end

    # A palette card and a hover preview render one of these on its own, with no form around it and
    # no `:let` variable in scope. A binding here would render as nothing;
    # `PageForms.FormPlacement` rewrites it into one on the way in instead.
    test "the bare controls carry a literal name, so they render standalone" do
      for id <- ~w(el-input el-textarea el-select el-checkbox el-radio-group) do
        {:ok, tree} = Tree.parse(Elements.get(id).template)

        assert Enum.any?(Tree.walk(tree), &match?({:string, _name}, named(&1))),
               "#{id} has no literal name, so its palette card renders an unnamed control"
      end
    end

    # An unticked checkbox sends nothing at all, so the hidden field beside it is what makes the
    # difference between "false" and "the visitor never saw this form".
    test "the checkbox sends false when it is left unticked" do
      {:ok, tree} = Tree.parse(Elements.get("el-checkbox").template)

      values =
        tree
        |> Tree.walk()
        |> Enum.filter(&(&1.tag == "input"))
        |> Enum.map(&{node_attr(&1, "type"), node_attr(&1, "name"), node_attr(&1, "value")})

      assert values == [{"hidden", "agree", "false"}, {"checkbox", "agree", "true"}]
    end

    test "the radio group shares one name across its options" do
      {:ok, tree} = Tree.parse(Elements.get("el-radio-group").template)

      radios = tree |> Tree.walk() |> Enum.filter(&(node_attr(&1, "type") == "radio"))

      assert length(radios) == 2
      assert radios |> Enum.map(&node_attr(&1, "name")) |> Enum.uniq() == ["choice"]
      assert Enum.map(radios, &node_attr(&1, "value")) == ["one", "two"]
    end

    # THE LITERAL NAME IS ONLY HALF THE PROMISE. The other half is that dropping one turns it into a
    # binding — and for the checkbox and the radio group it did not, because both put a `<label>` or
    # a `<fieldset>` at the head and only the head was ever asked. Both went on posting their literal
    # name at the event's top level, where `PageForm.scoped/2` never looks, so what the visitor
    # ticked was dropped from every submission with a green audit behind it.
    test "every bare control is rewritten into a binding when it is dropped into a form" do
      {session, form_id} = empty_form()

      for id <- ~w(el-input el-textarea el-select el-checkbox el-radio-group) do
        {template, false} = FormPlacement.wrap(Elements.get(id).template, session, form_id)

        refute template =~ ~r/name="[^"]+"/,
               "#{id} still posts a literal name, outside the form's own scope"

        assert template =~ ~s(name={g[:),
               "#{id} was not bound to the form it landed in"
      end
    end
  end

  defp empty_form do
    {:ok, tree} =
      Tree.parse(~s(<.form :let={g} id="q-form" as={:q} for={assigns[:q_form]}></.form>))

    form = tree |> Tree.walk() |> Enum.find(&(&1.tag == ".form"))

    {%{tree: tree, components: []}, form.id}
  end

  defp named(node), do: Node.attr(node, "name")

  defp node_attr(node, name),
    do: Node.attr_text(node, name)

  test "get/1 answers nil for something that is not an element" do
    assert Elements.get("hero-centred") == nil
    assert Elements.get("el-section").title == "Section"
  end

  # WHAT AN EXPRESSION CAN NAME DEPENDS ON WHAT IS BEING EDITED. `{@inner_content}` is the whole
  # point of a layout — it is where the page goes — and `render_slot(@inner_block)` is where a
  # component's content goes. Both could be SEEN in a document that already had one, and put there
  # only by opening the code drawer. Offering them everywhere is the opposite mistake: a page is
  # never handed `@inner_content`, so taking it would produce a document that does not compile.
  describe "the elements a section may use" do
    test "a layout is offered the page content slot and a component is not" do
      layout = Enum.map(Elements.for_section("layout"), & &1.id)
      component = Enum.map(Elements.for_section("component"), & &1.id)
      page = Enum.map(Elements.for_section("page"), & &1.id)

      assert "el-inner-content" in layout
      refute "el-inner-content" in component
      refute "el-inner-content" in page
    end

    test "a component is offered its own content and property expressions" do
      component = Enum.map(Elements.for_section("component"), & &1.id)

      assert "el-inner-block" in component
      assert "el-attr" in component
      refute "el-inner-block" in Enum.map(Elements.for_section("layout"), & &1.id)
    end

    test "a bare expression is offered in every document, because any of them can evaluate one" do
      for section <- ~w(page layout component error-page) do
        assert "el-assign" in Enum.map(Elements.for_section(section), & &1.id),
               "#{section} could not place a plain expression"
      end
    end

    test "an unscoped section still gets everything that belongs everywhere" do
      unscoped = Enum.map(Elements.all(), & &1.id)

      assert "el-section" in unscoped
      assert "el-assign" in unscoped

      assert "el-inner-content" in unscoped,
             "`all/0` is the catalogue — `for_section/1` is the question about a document"
    end

    test "searching is scoped the same way listing is" do
      assert "el-inner-content" in Enum.map(Elements.search("content", "layout"), & &1.id)
      refute "el-inner-content" in Enum.map(Elements.search("content", "page"), & &1.id)
    end

    test "every dynamic element writes an expression the parser reads back as one" do
      for element <-
            Enum.filter(
              Elements.for_section("component") ++ Elements.for_section("layout"),
              &(&1.category == "Dynamic")
            ) do
        {:ok, tree} = MishkaCmsCore.Runtime.Authoring.Tree.parse(element.template)

        assert Enum.map(MishkaCmsCore.Runtime.Authoring.Tree.walk(tree), & &1.kind) == [:eex],
               "#{element.id} did not parse as a single expression"
      end
    end
  end
end
