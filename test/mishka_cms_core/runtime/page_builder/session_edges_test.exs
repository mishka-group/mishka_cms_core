defmodule MishkaCmsCore.Runtime.PageBuilder.SessionEdgesTest do
  @moduledoc """
  The session functions that nothing tested: opening a draft, replacing the palette, putting flushed
  history rows back, and clearing marks.

  Each of them is reached from the editor rather than from a test, which is why they had none — and
  each is a place where a quiet mistake would be invisible. `requeue/2` puts entries back after a
  failed write, so losing them there means the record of an afternoon's work disappears with nothing
  said; `put_components/2` announces rather than stores, and a canvas that renders before the palette
  lands binds every component against an empty list and shows the runtime's red failure box.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node

  @moduletag :unit

  defp open(template \\ ~s(<div id="root"><p>hello</p></div>), attrs \\ %{}) do
    {:ok, session} = EditorSession.open(Map.merge(%{section: "page", template: template}, attrs))
    session
  end

  # `at` is what the queue sorts by, so an entry without one cannot be drained.
  defp entry do
    %{id: Ecto.UUID.generate(), label: "Edited text", kind: :content, at: DateTime.utc_now()}
  end

  # THE TEMPLATE IS PASSED IN NOW. `edit_draft/3` used to reach for `draft.template`, which only
  # three of the four draft resources have — `ErrorPageDraft` keeps `error_pages` — so the caller
  # asks `MishkaCmsCore.Runtime.PageBuilder.Section.template/3` and hands over the answer.
  describe "opening a draft into a live session" do
    test "replaces the document and names what is being edited" do
      session = open()

      {:ok, editing} =
        EditorSession.edit_draft(
          session.token,
          %{id: "draft-1", label: "Tuesday's draft"},
          ~s(<div id="root"><h2>from the draft</h2></div>)
        )

      assert editing.draft_id == "draft-1"
      assert editing.draft_label == "Tuesday's draft"
      assert Enum.any?(Tree.walk(editing.tree), &(&1.tag == "h2"))
    end

    test "and it starts clean, because nothing has been changed yet" do
      session = open()
      {:ok, dirty} = EditorSession.replace_text(session.token, "hello", "goodbye")
      assert dirty.dirty?

      {:ok, editing} =
        EditorSession.edit_draft(
          dirty.token,
          %{id: "draft-1", label: "A draft"},
          ~s(<div id="root"><p>hello</p></div>)
        )

      refute editing.dirty?
      assert editing.selection == nil
    end

    test "a draft that will not parse is reported rather than half-applied" do
      session = open()

      assert {:error, _reason} =
               EditorSession.edit_draft(
                 session.token,
                 %{id: "draft-1", label: "Broken"},
                 "<div><span></div>"
               )

      {:ok, unchanged} = EditorSession.fetch(session.token)
      assert unchanged.draft_id == nil
    end
  end

  describe "the palette arriving after the editor" do
    test "is stored on the session for the canvas to bind against" do
      session = open()
      entries = [%{key: "a", name: "a"}, %{key: "b", name: "b"}]

      {:ok, loaded} = EditorSession.put_components(session.token, entries)

      assert loaded.components == entries
      assert {:ok, %{components: ^entries}} = EditorSession.fetch(session.token)
    end
  end

  describe "history rows put back after a failed write" do
    test "are waiting for the next flush" do
      session = open()
      entry = entry()

      :ok = EditorSession.requeue(session.token, [entry])

      assert {:ok, [^entry]} = EditorSession.drain_pending(session.token)
    end

    # A retry must not turn one change into two rows: the entry carries its own id, and the row it
    # was already written to is the one it upserts onto.
    test "and an entry already queued is not queued twice" do
      session = open()
      entry = entry()

      :ok = EditorSession.requeue(session.token, [entry])
      :ok = EditorSession.requeue(session.token, [entry])

      assert {:ok, [^entry]} = EditorSession.drain_pending(session.token)
    end

    test "draining leaves nothing behind" do
      session = open()
      entry = entry()

      :ok = EditorSession.requeue(session.token, [entry])
      {:ok, _drained} = EditorSession.drain_pending(session.token)

      assert {:ok, []} = EditorSession.drain_pending(session.token)
    end
  end

  describe "holding more than one node" do
    test "marks are cleared without touching the selection" do
      session = open(~s(<div id="root"><p>one</p><h2>two</h2></div>))
      [first, second] = Tree.walk(session.tree) |> Enum.filter(&(&1.tag in ~w(p h2)))

      {:ok, selected} = EditorSession.select(session.token, first.id)
      {:ok, marked} = EditorSession.mark(selected.token, second.id)
      assert MapSet.size(marked.marked) == 1

      {:ok, cleared} = EditorSession.clear_marks(marked.token)

      assert MapSet.size(cleared.marked) == 0
      assert cleared.selection == first.id
    end

    # `chosen/1` answers WHICH, not in what order — the selection first and the held ones after it.
    # Document order is imposed by `topmost/2` on the way into a bulk action, which is the only
    # caller and the only place it matters.
    test "and everything held comes back, the selection first" do
      session = open(~s(<div id="root"><p>one</p><h2>two</h2><h3>three</h3></div>))
      [first, second, third] = Tree.walk(session.tree) |> Enum.filter(&(&1.tag in ~w(p h2 h3)))

      {:ok, selected} = EditorSession.select(session.token, third.id)
      {:ok, marked} = EditorSession.mark(selected.token, first.id)
      {:ok, marked} = EditorSession.mark(marked.token, second.id)

      assert [selected_id | rest] = EditorSession.chosen(marked)
      assert selected_id == third.id
      assert Enum.sort(rest) == Enum.sort([first.id, second.id])
    end

    # And the guarantee the callers actually depend on: wrapping three cards keeps the order they
    # read in on the page, not the order they were clicked.
    test "a bulk action over them works in document order" do
      session = open(~s(<div id="root"><p>one</p><h2>two</h2><h3>three</h3></div>))
      [first, second, third] = Tree.walk(session.tree) |> Enum.filter(&(&1.tag in ~w(p h2 h3)))

      {:ok, selected} = EditorSession.select(session.token, third.id)
      {:ok, marked} = EditorSession.mark(selected.token, first.id)
      {:ok, marked} = EditorSession.mark(marked.token, second.id)

      {:ok, wrapped} = EditorSession.bulk(marked.token, "wrap")

      wrapper =
        Enum.find(Tree.walk(wrapped.tree), &(&1.tag == "div" and length(&1.children) == 3))

      assert Enum.map(Tree.children(wrapped.tree, wrapper.id), & &1.tag) == ~w(p h2 h3)
    end
  end

  # THE SCOPE CLASS IS THE KEY THE ELEMENT'S OWN CSS IS WRITTEN AGAINST and the handle an
  # interaction points at. Clearing the class row took both with it, silently.
  describe "clearing the class attribute" do
    test "keeps the scope class while something still names it" do
      session = open(~s(<div id="root"><button>Go</button></div>))
      node = Enum.find(Tree.walk(session.tree), &(&1.tag == "button"))
      {tree, scope} = Tree.ensure_scope(session.tree, node.id)

      {:ok, tree} =
        Tree.set_attr(tree, node.id, "phx-click", ~s|JS.toggle_class("on", to: ".#{scope}")|)

      {:ok, cleared} = Tree.delete_attr(tree, node.id, "class")

      assert Tree.scope(cleared, node.id) == scope
    end

    test "and clears it completely when nothing does" do
      session = open(~s(<div id="root"><button class="px-4 py-2">Go</button></div>))
      node = Enum.find(Tree.walk(session.tree), &(&1.tag == "button"))

      {:ok, cleared} = Tree.delete_attr(session.tree, node.id, "class")

      assert Node.attr(Tree.get(cleared, node.id), "class") == nil
    end
  end
end
