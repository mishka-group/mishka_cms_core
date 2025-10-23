defmodule MishkaCmsCore.Runtime.PageBuilder.SlotStyleSavedTest do
  @moduledoc """
  The document a page is COMPILED FROM, for an override recorded against a slot.

  The canvas draws a slot's override with `!` because it has to beat the kit's own rule from inside
  the component's template, and the parser reads one back with `!`. The serializer wrote it without
  — so padding set on a `<:item>` painted on the canvas, survived a reopen (the parse is forgiving),
  and was absent from every published page. Three places decide this and only the two that a test
  looked at agreed.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @template ~s(<div id="root"><.component component_name="chelekom-list" site="Global"><:item>Contact</:item></.component></div>)

  defp styled(kind, prop \\ "padding", value \\ "8") do
    {:ok, tree} = Tree.parse(@template)
    node = Enum.find(Tree.walk(tree), &(&1.kind == kind))
    {:ok, tree} = Tree.set_style(tree, node.id, :base, prop, value)
    {node, tree, Serializer.serialize(tree)}
  end

  test "a slot's override is saved with the bang the canvas drew it with" do
    {_node, _tree, html} = styled(:slot)

    assert html =~ ~s(<:item class="p-[8px]!">)
    refute html =~ ~s(<:item class="p-[8px]">)
  end

  test "a component's override still is, which was never in doubt" do
    {_node, _tree, html} = styled(:component)

    assert html =~ ~s(p-[8px]!)
  end

  # THE OTHER HALF OF THE RULE. A plain tag's override must NOT carry one — a bang there beats the
  # author's own later rules for no reason, and `Tree.extract_styles/2` reads a tag without it.
  test "a plain tag's override is saved without one" do
    {:ok, tree} = Tree.parse(~s(<div id="root"><p>hello</p></div>))
    p = Enum.find(Tree.walk(tree), &(&1.tag == "p"))
    {:ok, tree} = Tree.set_style(tree, p.id, :base, "padding", "8")

    html = Serializer.serialize(tree)
    assert html =~ ~s(<p class="p-[8px]">)
    refute html =~ "p-[8px]!"
  end

  # WHAT THE BUG ACTUALLY COST. The saved class is what the compiler emits, so this is the assertion
  # that speaks for the published page rather than for the editor.
  test "the saved class is the one that beats the kit's own rule" do
    {_node, _tree, html} = styled(:slot)

    [class] = Regex.run(~r/<:item class="([^"]*)"/, html, capture: :all_but_first)

    assert String.ends_with?(class, "!"),
           "a slot override without ! loses to the component's own class"
  end

  test "and it round-trips: saved, reparsed, still recorded as an override" do
    {_node, _tree, html} = styled(:slot)

    {:ok, back} = Tree.parse(html)
    slot = Enum.find(Tree.walk(back), &(&1.kind == :slot))

    assert slot.meta[:styles] == %{base: %{"padding" => "8px"}}
    assert Tree.Node.attr_text(slot, "class") in [nil, ""]
  end
end
