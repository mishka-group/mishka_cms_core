# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.DocumentRootTest do
  @moduledoc """
  What may happen at the root of a document-rooted tree.

  A layout's root is `<body>` — every one in this CMS opens with it, and
  `MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive` draws it as a `div` precisely so the frame can
  hold it. That substitution is what made these three invisible: wrapping the root produced
  `<div><body>…</body></div>`, duplicating it produced a layout with two `<body>` roots, and a drop
  or a paste resolved to `:root` landed a sibling of `<body>` — markup after `</body>` — and the
  canvas drew all of it as ordinary divs, so it looked exactly right.

  Nothing objected either: `validate_parent(_tree, :root)` answered `:ok` unconditionally, and the
  publish gate asks only whether `@inner_content` is still rendered.

  `insert/4` is the one funnel — `duplicate/2`, `wrap/3`, every drop and every paste reach it — so
  the rule lives there, in two halves: content aimed at the root of such a tree goes INSIDE the
  document element, and the document element itself cannot be wrapped or duplicated.
  """
  use ExUnit.Case, async: true
  @moduletag :unit

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  @layout ~s(<body class="page"><main>{@inner_content}</main></body>)
  @page ~s(<section id="root"><p>hi</p></section>)

  defp tree(source), do: Tree.parse!(source)
  defp root_node(tree), do: tree.roots |> hd() |> then(&Tree.get(tree, &1))
  defp source(tree), do: Serializer.serialize(tree)

  defp fresh(tag), do: Node.new(:tag, tag: tag)

  describe "a layout, whose root is <body>" do
    test "content aimed at the root lands inside it, not after </body>" do
      tree = tree(@layout)

      {:ok, tree} = Tree.insert(tree, fresh("aside"), :root, 99)

      out = source(tree)

      assert out =~ "<aside></aside>"
      assert [_one] = tree.roots, "a second root was created beside <body>"

      refute Regex.match?(~r|</body>\s*<aside|, out),
             "the element was written outside the document: #{out}"
    end

    test "the document element cannot be wrapped" do
      tree = tree(@layout)

      assert {:error, :document_root} =
               Tree.wrap(tree, root_node(tree).id, fresh("div"))
    end

    test "nor duplicated" do
      tree = tree(@layout)

      assert {:error, :document_root} = Tree.duplicate(tree, root_node(tree).id)
    end

    # AND IT CANNOT BE TAKEN OFF. `unwrap/2` promotes a node's children into its place and then
    # deletes it, so unwrapping `<body>` leaves a layout whose markup has none — the frame drew it as
    # a div, so the canvas looked identical, and the layout was published with its document element
    # missing. The other two refusals were added and this one was not; the way in is the same
    # right-click menu.
    test "nor unwrapped" do
      tree = tree(@layout)

      assert {:error, :document_root} = Tree.unwrap(tree, root_node(tree).id)
    end

    test "but what is inside it still wraps and duplicates normally" do
      tree = tree(@layout)
      main = tree |> Tree.walk() |> Enum.find(&(&1.tag == "main"))

      assert {:ok, wrapped} = Tree.wrap(tree, main.id, fresh("div"))
      assert source(wrapped) =~ "<div><main>"

      assert {:ok, _duplicated, _id} = Tree.duplicate(tree, main.id)
    end
  end

  # THE WAY A LAYOUT ACTUALLY ARRIVES. `Serializer.to_heex/1` ends its output with a newline, so every
  # layout in the database is stored as `…</body>\n`. The fixtures above have no such newline, and a
  # tree with a second ROOT — text or otherwise — is precisely what would make `document_root/1`
  # answer nil and silently switch off every protection built on it. The tokenizer folds that
  # trailing newline into the body rather than beside it; these pin that, because the day it stops
  # being true nothing else in the suite would notice.
  describe "a layout as it is stored, with a newline after </body>" do
    @stored @layout <> "\n"

    test "and its document element cannot be duplicated" do
      tree = tree(@stored)

      assert {:error, :document_root} = Tree.duplicate(tree, body_id(tree))
    end

    test "nor wrapped" do
      tree = tree(@stored)

      assert {:error, :document_root} = Tree.wrap(tree, body_id(tree), fresh("div"))
    end

    test "nor unwrapped" do
      tree = tree(@stored)

      assert {:error, :document_root} = Tree.unwrap(tree, body_id(tree))
    end

    test "and content aimed at the root still lands inside it" do
      tree = tree(@stored)

      {:ok, tree} = Tree.insert(tree, fresh("aside"), :root, 99)

      out = source(tree)

      refute Regex.match?(~r|</body>\s*<aside|, out),
             "the element was written after </body>: #{out}"
    end

    defp body_id(tree) do
      tree |> Tree.walk() |> Enum.find(&(&1.tag == "body")) |> Map.fetch!(:id)
    end
  end

  describe "a page, which is not document-rooted" do
    test "still takes content at its root" do
      tree = tree(@page)

      {:ok, tree} = Tree.insert(tree, fresh("aside"), :root, 99)

      assert length(tree.roots) == 2, "a page's root is a list and stays one"
      assert source(tree) =~ "</section><aside>"
    end

    test "and its root element wraps, duplicates and unwraps as before" do
      tree = tree(@page)

      assert {:ok, wrapped} = Tree.wrap(tree, root_node(tree).id, fresh("div"))
      assert source(wrapped) =~ "<div><section"

      assert {:ok, _tree, _id} = Tree.duplicate(tree, root_node(tree).id)

      assert {:ok, unwrapped} = Tree.unwrap(tree, root_node(tree).id)
      assert source(unwrapped) == "<p>hi</p>"
    end
  end
end
