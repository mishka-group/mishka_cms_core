# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.LinkATextTest do
  @moduledoc """
  Turning words on a page into a link, which was reachable only by hand-writing the `<a>` into the
  code drawer.

  The action is one word — `"link"` — and the whole of its judgement is WHERE the `<a>` goes. A list
  item cannot have anything put around it, so its contents are linked; everything else is linked
  itself. Both come back with an `href` already on them, because an `<a>` without one draws no
  control in the inspector and so leaves the author exactly where they started.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer

  defp open(template) do
    {:ok, session} = EditorSession.open(%{section: "page", template: template})
    session
  end

  defp html(session), do: Serializer.serialize(session.tree)
  defp find(session, tag), do: Enum.find(Tree.walk(session.tree), &(&1.tag == tag))

  defp text(session, words),
    do: Enum.find(Tree.walk(session.tree), &(&1.kind == :text and String.trim(&1.text) == words))

  describe "context_action/3 \"link\"" do
    test "a run of text becomes a link where it stands" do
      session = open(~s(<div id="root"><h2>About us</h2></div>))

      assert {:ok, linked} =
               EditorSession.context_action(session.token, "link", text(session, "About us").id)

      assert html(linked) == ~s(<div id="root"><h2><a href="#">About us</a></h2></div>)
    end

    test "an ordinary element is linked itself" do
      session = open(~s(<div id="root"><p>hello</p></div>))

      assert {:ok, linked} =
               EditorSession.context_action(session.token, "link", find(session, "p").id)

      assert html(linked) == ~s(<div id="root"><a href="#"><p>hello</p></a></div>)
    end

    # THE REPORTED CASE. Clicking the words of a list item selects the `li`, because on the canvas
    # the words are the item — and `<ul><a><li>` is a document no browser keeps, so the link has to
    # go inside.
    test "a list item links its contents, because nothing may be put around it" do
      session = open(~s(<div id="root"><ul><li>Contact</li><li>Terms</li></ul></div>))

      assert {:ok, linked} =
               EditorSession.context_action(session.token, "link", find(session, "li").id)

      assert html(linked) ==
               ~s(<div id="root"><ul><li><a href="#">Contact</a></li><li>Terms</li></ul></div>)
    end

    test "a table cell does the same, on the same rule" do
      session = open(~s(<div id="root"><table><tr><td>Row</td></tr></table></div>))

      assert {:ok, linked} =
               EditorSession.context_action(session.token, "link", find(session, "td").id)

      assert html(linked) =~ ~s(<td><a href="#">Row</a></td>)
    end

    test "several children of one item are gathered into a single link" do
      session = open(~s(<div id="root"><ul><li><b>Go</b> <span>home</span></li></ul></div>))

      assert {:ok, linked} =
               EditorSession.context_action(session.token, "link", find(session, "li").id)

      assert html(linked) ==
               ~s(<div id="root"><ul><li><a href="#"><b>Go</b> <span>home</span></a></li></ul></div>)
    end

    test "the href is a real attribute, so the inspector has a field to offer" do
      session = open(~s(<div id="root"><p>hello</p></div>))

      {:ok, linked} = EditorSession.context_action(session.token, "link", find(session, "p").id)

      assert {"href", {:string, "#"}} in find(linked, "a").attrs
    end

    # A SLOT HAS TO STAY A DIRECT CHILD OF ITS COMPONENT, so the link goes inside it — which is what
    # a kit list is made of, the reported case exactly.
    test "a slot links its contents rather than itself" do
      session =
        open(
          ~s(<div id="root"><.component component_name="chelekom-list" site="Global">) <>
            ~s(<:item>Contact</:item></.component></div>)
        )

      slot = Enum.find(Tree.walk(session.tree), &(&1.kind == :slot))

      assert {:ok, linked} = EditorSession.context_action(session.token, "link", slot.id)
      assert html(linked) =~ ~s(<:item><a href="#">Contact</a></:item>)
    end

    test "an empty item has nothing to link and says so" do
      session = open(~s(<div id="root"><ul><li></li></ul></div>))

      assert {:error, :nothing_to_link} =
               EditorSession.context_action(session.token, "link", find(session, "li").id)
    end

    # A BROWSER REPAIRS `<a><a>` BY CLOSING THE FIRST ONE, so a document that accepted this would
    # read back differently from the one the author built.
    test "a link inside a link is refused rather than written" do
      session = open(~s(<div id="root"><p><a href="/x">already</a></p></div>))

      assert {:error, :already_linked} =
               EditorSession.context_action(session.token, "link", find(session, "p").id)

      assert {:error, :already_linked} =
               EditorSession.context_action(
                 session.token,
                 "link",
                 text(session, "already").id
               )
    end

    test "a node that is no longer there is refused, not crashed through" do
      session = open(~s(<div id="root"><p>hello</p></div>))

      assert {:error, :unknown_node} =
               EditorSession.context_action(session.token, "link", "nzzzzzzzz")
    end

    test "linking is one history step, so one undo takes it back" do
      session = open(~s(<div id="root"><ul><li>Contact</li></ul></div>))
      before = html(session)

      {:ok, linked} = EditorSession.context_action(session.token, "link", find(session, "li").id)
      assert {:ok, undone} = EditorSession.undo(linked.token)

      assert html(undone) == before
    end
  end
end
