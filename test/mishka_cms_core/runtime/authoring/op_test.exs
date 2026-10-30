# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.Authoring.OpTest do
  @moduledoc """
  What a property write with no stated kind stores on an attribute that holds an expression.

  A property box shows a binding's source and posts it back as plain text, so a write that says no
  kind keeps the binding. What the author typed over it is a different matter when it reads
  nothing: `E2E-0` parses as the alias `E2E` minus zero, was stored as `input_value={E2E - 0}`, and
  every visitor of the published page got an HTTP 500.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.Authoring.Op
  alias MishkaCmsCore.Runtime.Authoring.Tree
  alias MishkaCmsCore.Runtime.Authoring.Tree.Node

  defp bound_field do
    tree = Tree.parse!(~S(<input name={f[:email].name} value={f[:email].value} />))
    {tree, tree |> Tree.walk() |> Enum.find(&(&1.tag == "input"))}
  end

  defp write(tree, node, value, extra \\ %{}) do
    {:ok, op} =
      Op.build(
        Map.merge(%{kind: :set_attr, node_id: node.id, name: "value", value: value}, extra)
      )

    {:ok, written} = Op.apply_to(op, tree)
    written |> Tree.get(node.id) |> Node.attr("value")
  end

  test "words typed over a binding are stored as the words" do
    {tree, node} = bound_field()

    assert write(tree, node, "E2E-0") == {:string, "E2E-0"}
    assert write(tree, node, "hello world") == {:string, "hello world"}
    assert write(tree, node, "1-2") == {:string, "1-2"}
  end

  test "a binding written back, or a new one, stays an expression" do
    {tree, node} = bound_field()

    assert write(tree, node, "f[:email].value") == {:expr, "f[:email].value"}
    assert write(tree, node, "@email") == {:expr, "@email"}
  end

  # A loop's own variable is a bare name, which is a word when typed; posted back unchanged it is the
  # binding the box was showing.
  test "a bare binding posted back unchanged stays one" do
    tree = Tree.parse!(~S(<input value={item} />))
    node = tree |> Tree.walk() |> Enum.find(&(&1.tag == "input"))

    assert write(tree, node, "item") == {:expr, "item"}
    assert write(tree, node, "other") == {:string, "other"}
  end

  # `{45}`, `{:danger}` and `{true}` are how the editor writes a number, an atom and a boolean, and a
  # box showing one posts it back the same way.
  test "a literal over a binding stays an expression" do
    {tree, node} = bound_field()

    assert write(tree, node, "45") == {:expr, "45"}
    assert write(tree, node, ":danger") == {:expr, ":danger"}
  end

  test "a stated kind still wins" do
    {tree, node} = bound_field()

    assert write(tree, node, "E2E-0", %{value_kind: "expr"}) == {:expr, "E2E-0"}
    assert write(tree, node, "@email", %{value_kind: "string"}) == {:string, "@email"}
  end
end
