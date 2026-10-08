defmodule MishkaCmsCore.Runtime.PageBuilder.CommentTest do
  @moduledoc """
  The review note itself: what it accepts, what it refuses, and the two derived values the sheet
  renders (the resolved partition and the coarse relative time).
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.Comment

  describe "new/1" do
    test "builds a note anchored to a node" do
      assert {:ok, comment} =
               Comment.new(%{
                 text: "Tighten this heading",
                 node_id: "nabcdefgh",
                 node_label: "h2"
               })

      assert comment.text == "Tighten this heading"
      assert comment.node_id == "nabcdefgh"
      assert comment.node_label == "h2"
      refute comment.resolved?
      assert %DateTime{} = comment.at
    end

    test "a note with no node is about the whole page, not an error" do
      assert {:ok, comment} = Comment.new(%{text: "Needs a meta description"})
      assert comment.node_id == nil
      assert comment.node_label == "the whole page"
    end

    test "ids are unique and shaped like the tree's" do
      {:ok, one} = Comment.new(%{text: "a"})
      {:ok, two} = Comment.new(%{text: "b"})

      assert one.id != two.id
      assert one.id =~ ~r/^c[a-z0-9]{8}$/
    end

    # A note is rendered as prose, so markup in it is never wanted — and because the markup goes
    # before the derives run, a note that was only markup or only whitespace ends up empty and is
    # refused.
    test "markup is stripped out of the note" do
      assert {:ok, comment} = Comment.new(%{text: "<b>bold</b> claim"})
      assert comment.text == "bold claim"
    end

    test "the note, its author and its label are kept as typed, without markup" do
      assert {:ok, comment} =
               Comment.new(%{
                 text: ~s(Tom & Jerry's <b>"cat"</b>),
                 author: "<i>Ada</i> & co",
                 node_label: "<h2> & <p>"
               })

      assert comment.text == ~s(Tom & Jerry's "cat")
      assert comment.author == "Ada & co"
      assert comment.node_label == "&"

      assert {:ok, again} = Comment.new(Map.take(comment, [:text, :author, :node_label]))

      assert Map.take(again, [:text, :author, :node_label]) ==
               Map.take(comment, [:text, :author, :node_label])
    end

    test "a script never survives in a note" do
      assert {:ok, comment} = Comment.new(%{text: "<script>alert(1)</script>Hi"})
      assert comment.text == "alert(1)Hi"
    end

    test "a blank note is refused" do
      assert {:error, _reason} = Comment.new(%{text: "   "})
      assert {:error, _reason} = Comment.new(%{text: ""})
    end

    test "a note that was nothing but markup is refused too" do
      assert {:error, _reason} = Comment.new(%{text: "<br/>"})
    end

    test "an author is recorded, and defaults rather than failing without one" do
      {:ok, named} = Comment.new(%{text: "x", author: "ada.love", author_id: "u1"})
      {:ok, anonymous} = Comment.new(%{text: "x"})

      assert named.author == "ada.love"
      assert named.author_id == "u1"
      assert anonymous.author == "Someone"
    end
  end

  describe "resolve/1 and open/1" do
    test "resolving flips the flag and takes the note out of the open list" do
      {:ok, one} = Comment.new(%{text: "one"})
      {:ok, two} = Comment.new(%{text: "two"})

      resolved = Comment.resolve(one)

      assert resolved.resolved?
      assert Comment.open([resolved, two]) == [two]
    end

    test "resolving twice is harmless" do
      {:ok, comment} = Comment.new(%{text: "one"})
      assert comment |> Comment.resolve() |> Comment.resolve() |> Map.fetch!(:resolved?)
    end
  end

  describe "ago/2" do
    setup do
      %{now: ~U[2026-07-30 12:00:00Z]}
    end

    test "reads coarsely, in the units a thread cares about", %{now: now} do
      at = fn seconds -> %{at: DateTime.add(now, -seconds, :second)} end

      assert Comment.ago(at.(5), now) == "just now"
      assert Comment.ago(at.(59), now) == "just now"
      assert Comment.ago(at.(240), now) == "4m"
      assert Comment.ago(at.(3 * 3600), now) == "3h"
      assert Comment.ago(at.(2 * 86_400), now) == "2d"
    end

    test "a note with no timestamp renders nothing rather than raising", %{now: now} do
      assert Comment.ago(%{at: nil}, now) == ""
    end
  end
end
