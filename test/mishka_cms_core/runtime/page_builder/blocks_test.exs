# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.BlocksTest do
  @moduledoc """
  The section library, and the one property the placement rule depends on.

  `EditorSession.place_at/2` treats a `<section>`, `<header>`, `<footer>` or `<main>` as a slice of
  the page and lands it beside the other slices instead of inside whatever was selected. That rule
  reads the first root tag of the template it is given, so a block whose template started with a
  `<div>` would quietly be treated as a leaf and land back inside the header it was clicked into —
  the exact bug the rule exists to fix, returning without a failing test anywhere.

  Pinning it here rather than in the placement tests is deliberate: this is a property of the
  library, and it has to hold for block nine as much as for the eight shipped today.

  The Forms blocks carry a second property. A form block is only worth shipping if it is a WORKING
  form — one that names a page assign, scopes its params, binds every field to a key and points at
  the two events the compiler generates. A block that merely looks like a form teaches an author the
  wrong shape and then does nothing when a visitor presses the button.
  """
  use ExUnit.Case, async: true

  @moduletag :unit

  alias MishkaCmsCore.Runtime.PageBuilder.Blocks
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @bands ~w(section header footer main)

  defp nodes_of(id) do
    {:ok, tree} = id |> Blocks.fetch() |> Map.fetch!(:template) |> Tree.parse()
    Tree.walk(tree)
  end

  defp has_class?(node, utility) do
    case Node.attr_text(node, "class") do
      class when is_binary(class) -> String.contains?(class, utility)
      _unset -> false
    end
  end

  defp head(template) do
    {:ok, tree} = Tree.parse(template)
    tree |> Tree.get(hd(tree.roots))
  end

  describe "the library" do
    test "ships blocks, each with an id, a title, a category and a template" do
      blocks = Blocks.all()

      refute Enum.empty?(blocks)

      for block <- blocks do
        assert is_binary(block.id) and block.id != ""
        assert is_binary(block.title) and block.title != ""
        assert is_binary(block.category) and block.category != ""
        assert is_binary(block.template) and block.template != ""
      end
    end

    test "every id is unique, because a pick is resolved by id" do
      ids = Enum.map(Blocks.all(), & &1.id)
      assert ids == Enum.uniq(ids)
    end

    test "fetch/1 finds a block by id and returns nil for anything else" do
      first = hd(Blocks.all())

      assert Blocks.fetch(first.id).title == first.title
      assert Blocks.fetch("no-such-block") == nil
    end
  end

  describe "what placement depends on" do
    test "every block's template parses" do
      for block <- Blocks.all() do
        assert {:ok, _tree} = Tree.parse(block.template), "#{block.id} does not parse"
      end
    end

    test "every block starts with a band tag" do
      for block <- Blocks.all() do
        node = head(block.template)

        assert node.kind == :tag, "#{block.id} starts with #{node.kind}, not a tag"

        assert String.downcase(node.tag) in @bands,
               "#{block.id} starts with <#{node.tag}>, which placement will treat as a leaf"
      end
    end
  end

  describe "the Forms blocks" do
    test "there are four of them" do
      assert Enum.map(forms(), & &1.id) ==
               ~w(form-contact form-fieldset form-newsletter form-subscribe-joined)
    end

    # THE SHAPE THE REPORT ASKED FOR, and the reason a block exists for it: a field and a button
    # sharing one border and one set of rounded corners is four decisions, each one utility, none of
    # them guessable. The border on the ROW, both children giving theirs up, the row clipping what
    # overflows its corners, and the field's own bottom margin gone. Asserted because a block that
    # loses any one of them is back to the gapped shape the newsletter block already ships.
    test "the subscribe box is joined, not two things beside each other" do
      nodes = nodes_of("form-subscribe-joined")
      row = Enum.find(nodes, &has_class?(&1, "overflow-hidden"))

      assert row, "the block no longer has a row to join anything in"

      for utility <- ~w(rounded-lg border [&>div]:mb-0 [&>div]:flex-1) do
        assert has_class?(row, utility), "the row lost #{utility}"
      end

      # `flex` and `items-stretch` are style vocabulary, so `Tree.parse/1` lifts them off the class
      # into the overrides the Inspector edits — which is where an author would change them too.
      assert get_in(row.meta, [:styles, :base]) == %{
               "display" => "flex",
               "align" => "items-stretch"
             }

      assert Enum.any?(nodes, &has_class?(&1, "border-0")),
             "the field keeps a border of its own, so there are two"
    end

    test "every one declares exactly one form" do
      for block <- forms() do
        assert [_spec] = PageForms.declared(block.template),
               "#{block.id} does not declare exactly one form"
      end
    end

    test "every one binds at least one field" do
      for block <- forms() do
        [spec] = PageForms.declared(block.template)

        refute spec.fields == [], "#{block.id} is a form with nothing in it"
      end
    end

    # All five names come from one seed, so a rename cannot leave the id, the params, the page assign
    # and the two events disagreeing. A shipped block that already disagreed would teach the shape
    # the editor spends its time preventing.
    test "the five names all derive from the one seed" do
      for block <- forms() do
        [spec] = PageForms.declared(block.template)

        assert spec.id == spec.as <> "-form", "#{block.id} has an id that is not its seed"
        assert spec.assign == String.to_existing_atom(spec.as <> "_form")
        assert spec.change == spec.as <> "_validate"
        assert spec.submit == spec.as <> "_submit"
      end
    end

    test "no two of them share a seed, so two on one page start out independent" do
      seeds = Enum.map(forms(), &hd(PageForms.declared(&1.template)).as)

      assert seeds == Enum.uniq(seeds)
    end

    test "every one says what the visitor is told afterwards" do
      for block <- forms() do
        [spec] = PageForms.declared(block.template)

        assert String.trim(spec.success) != "", "#{block.id} has no success message"
      end
    end

    # The contact form is the one the walkthrough uses, so its rules are pinned rather than merely
    # counted: they are what makes the difference between a form that submits anything and a form
    # that checks what it was given.
    test "the contact form carries the rules an author would have had to write" do
      [spec] = PageForms.declared(Blocks.fetch("form-contact").template)

      assert Enum.map(spec.fields, & &1.key) == [:name, :email, :message]

      assert rules(spec, :email) == [:required, {:format, :email}]
      assert rules(spec, :name) == [:required, {:min_length, 2}]
      assert rules(spec, :message) == [:required, {:min_length, 10}, {:max_length, 2000}]
    end

    # A BLOCK REACHES FOR NO KIT. `<.component>` is the node that resolves against the components
    # installed in this database, so a block carrying one renders the runtime's red failure box on an
    # install that has no kit — which is every fresh one.
    test "no block resolves a component out of the database" do
      for block <- Blocks.all() do
        {:ok, tree} = Tree.parse(block.template)

        refute Enum.any?(Tree.walk(tree), &(&1.tag == ".component")),
               "#{block.id} reaches for an installed component"
      end
    end
  end

  defp forms, do: Enum.filter(Blocks.all(), &(&1.category == "Forms"))

  defp rules(spec, key) do
    spec.fields
    |> Enum.find(&(&1.key == key))
    |> Map.fetch!(:rules)
  end
end
