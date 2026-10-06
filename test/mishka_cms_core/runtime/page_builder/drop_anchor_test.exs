defmodule MishkaCmsCore.Runtime.PageBuilder.DropAnchorTest do
  @moduledoc """
  Where a drop lands when the screen and the tree disagree about the order of things.

  The canvas used to send an INDEX, counted off the boxes it had drawn. That is the tree's child list
  only while every child draws exactly one box, and a component breaks it: a `:slot` child renders no
  element of its own — `CanvasLive.slot_assigns/3` splits it out and hands its children to the kit's
  own `render_slot`, wherever the kit's markup puts them — so the slot costs one place in
  `node.children` and nothing on screen, and its children then surface among the component's own.

  Every index measured after such a slot was one too low. Dropping a text field on the lower half of
  a textarea inside a form wrapper put it in FRONT of the textarea, every single time, and the only
  way to order the two was to pick up the other one instead.

  So the canvas now names what it was beside and the index is read here, off the list the op is about
  to be applied to. These tests are written against that shape directly rather than through a
  rendered canvas: what has to hold is that a tree position wins over a screen position, in both
  directions, and that an anchor which has gone leaves the payload alone.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree

  @moduletag :unit

  defp open(template) do
    {:ok, session} = EditorSession.open(%{section: "page", template: template})
    session
  end

  defp id(session, tag), do: Enum.find(Tree.walk(session.tree), &(&1.tag == tag)).id

  defp newest(before, session) do
    seen = before.tree |> Tree.walk() |> MapSet.new(& &1.id)

    session.tree |> Tree.walk() |> Enum.find(&(!MapSet.member?(seen, &1.id)))
  end

  defp order(session, parent_id), do: Tree.child_ids(session.tree, parent_id)

  defp at(session, parent_id, node_id),
    do: session |> order(parent_id) |> Enum.find_index(&(&1 == node_id))

  describe "a drop that names what it landed beside" do
    test "goes after it, whatever index the screen counted" do
      session = open(~s(<div id="root"><h2>one</h2><p>two</p><span>three</span></div>))
      root = id(session, "div")
      paragraph = id(session, "p")

      {:ok, dropped} =
        EditorSession.apply_drop(session.token, %{
          "template" => "<b>new</b>",
          # WHAT A MISCOUNTING CANVAS SENDS. `parent_id` and `index` here would put the node first;
          # the anchor is what overrules them.
          "parent_id" => root,
          "index" => 0,
          "anchor_id" => paragraph,
          "anchor_before" => false
        })

      added = newest(session, dropped)

      assert at(dropped, root, added.id) == at(dropped, root, paragraph) + 1
    end

    test "and before it when that is the side the pointer was on" do
      session = open(~s(<div id="root"><h2>one</h2><p>two</p><span>three</span></div>))
      root = id(session, "div")
      paragraph = id(session, "p")

      {:ok, dropped} =
        EditorSession.apply_drop(session.token, %{
          "template" => "<b>new</b>",
          "parent_id" => root,
          "index" => 9999,
          "anchor_id" => paragraph,
          "anchor_before" => true
        })

      added = newest(session, dropped)

      # The anchor is pushed along by the insertion, so "before it" is the place it just left.
      assert at(dropped, root, added.id) == at(dropped, root, paragraph) - 1
    end

    # The anchor carries its own parent, so a canvas that named the wrong one — which is what happens
    # to anything rendered inside a slot, where the nearest element with an id is the COMPONENT and
    # not the slot — still lands in the right place.
    test "in the anchor's own parent, not the one the payload claimed" do
      session = open(~s(<div id="root"><section><p>inner</p></section></div>))
      root = id(session, "div")
      section = id(session, "section")
      inner = id(session, "p")

      {:ok, dropped} =
        EditorSession.apply_drop(session.token, %{
          "template" => "<b>new</b>",
          "parent_id" => root,
          "index" => 0,
          "anchor_id" => inner,
          "anchor_before" => false
        })

      assert newest(session, dropped).parent_id == section
    end

    test "at the top level when the anchor is a root of the document" do
      session = open(~s(<h2>one</h2><p>two</p>))
      paragraph = id(session, "p")

      {:ok, dropped} =
        EditorSession.apply_drop(session.token, %{
          "template" => "<b>new</b>",
          "parent_id" => "root",
          "index" => 0,
          "anchor_id" => paragraph,
          "anchor_before" => false
        })

      added = newest(session, dropped)

      assert added.parent_id == nil
      assert List.last(dropped.tree.roots) == added.id
    end
  end

  describe "moving a node beside another" do
    # `Tree.move/4` counts with the moving node ALREADY REMOVED and the anchor is read while it is
    # still there, so the two disagree by one whenever the node is travelling forwards.
    # `settled_index/2` is what reconciles them, and it has to keep working now that the index it
    # corrects arrives from the tree rather than the screen.
    test "forwards, where the removal shifts everything after it" do
      session = open(~s(<div id="root"><h2>a</h2><p>b</p><span>c</span><b>d</b></div>))
      root = id(session, "div")
      heading = id(session, "h2")
      third = id(session, "span")

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => heading,
          "parent_id" => root,
          "index" => 0,
          "anchor_id" => third,
          "anchor_before" => false
        })

      assert at(moved, root, heading) == at(moved, root, third) + 1
    end

    test "backwards, where nothing shifts at all" do
      session = open(~s(<div id="root"><h2>a</h2><p>b</p><span>c</span><b>d</b></div>))
      root = id(session, "div")
      last = id(session, "b")
      first = id(session, "h2")

      {:ok, moved} =
        EditorSession.apply_drop(session.token, %{
          "node_id" => last,
          "parent_id" => root,
          "index" => 9999,
          "anchor_id" => first,
          "anchor_before" => true
        })

      assert at(moved, root, last) == 0
    end
  end

  describe "an anchor that is not there any more" do
    # A collaborator can delete the node a drag was aimed at while the gesture is still in flight.
    # The payload's own index is the fallback, which is what it was before the anchor existed.
    test "leaves the payload's own parent and index alone" do
      session = open(~s(<div id="root"><h2>one</h2><p>two</p></div>))
      root = id(session, "div")

      {:ok, dropped} =
        EditorSession.apply_drop(session.token, %{
          "template" => "<b>new</b>",
          "parent_id" => root,
          "index" => 0,
          "anchor_id" => "nzzzzzzzz",
          "anchor_before" => false
        })

      added = newest(session, dropped)

      assert added.parent_id == root
      assert at(dropped, root, added.id) == 0
    end

    test "and a payload with no anchor at all is untouched" do
      session = open(~s(<div id="root"><h2>one</h2><p>two</p></div>))
      root = id(session, "div")

      {:ok, dropped} =
        EditorSession.apply_drop(session.token, %{
          "template" => "<b>new</b>",
          "parent_id" => root,
          "index" => 1
        })

      assert at(dropped, root, newest(session, dropped).id) == 1
    end
  end
end
