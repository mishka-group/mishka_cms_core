defmodule MishkaCmsCore.Runtime.States.EditorSessionStateTest do
  @moduledoc """
  `find/3`'s scoping rules, pinned directly.

  The lookup is an ETS match spec rather than a filter over `tab2list`, because a session row carries
  the tree, its undo history and the site's palette and there may be one per open editor in the node.
  A match spec that is subtly wrong returns nothing and the editor silently mints a fresh session
  instead of resuming — which looks, from the outside, exactly like "there was nothing to resume".
  These are the four properties that would break quietly.
  """
  use ExUnit.Case, async: false

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.States.EditorSessionState

  setup do
    on_exit(fn -> Enum.each(EditorSessionState.tokens(), &EditorSessionState.delete/1) end)
    :ok
  end

  defp open!(overrides) do
    {:ok, session} =
      [template: "<div><p>hi</p></div>", section: "page"]
      |> Keyword.merge(overrides)
      |> Map.new()
      |> EditorSession.open()

    session
  end

  test "finds this actor's session on this document" do
    session = open!(resource_id: "doc-1", actor_id: "actor-1")

    assert {:ok, found} = EditorSessionState.find("page", "doc-1", "actor-1")
    assert found.token == session.token
  end

  # AN ERROR PAGE HOLDS ONE TEMPLATE PER STATUS, so the status is part of what a session is for.
  # Without it the editor handed back the session opened on 404 when the author asked for 500 — the
  # strip moved, the canvas did not, and the next save wrote one status over another.
  describe "the status a session is for" do
    test "separates two sessions on the same record" do
      four = open!(resource_id: "doc-1", actor_id: "actor-1", section: "error_page", status: 404)
      five = open!(resource_id: "doc-1", actor_id: "actor-1", section: "error_page", status: 500)

      refute four.token == five.token

      assert {:ok, %{token: found}} =
               EditorSessionState.find("error_page", "doc-1", "actor-1", 404)

      assert found == four.token

      assert {:ok, %{token: found}} =
               EditorSessionState.find("error_page", "doc-1", "actor-1", 500)

      assert found == five.token
    end

    test "and one asked for with a status it was not opened on is not offered" do
      open!(resource_id: "doc-1", actor_id: "actor-1", section: "error_page", status: 404)

      assert EditorSessionState.find("error_page", "doc-1", "actor-1", 500) == :error
    end

    # The other three keep no status, and must go on resuming exactly as before.
    test "a section without one still resumes" do
      session = open!(resource_id: "doc-1", actor_id: "actor-1")

      assert {:ok, found} = EditorSessionState.find("page", "doc-1", "actor-1", nil)
      assert found.token == session.token
    end
  end

  test "another actor's session on the same document is not offered" do
    open!(resource_id: "doc-1", actor_id: "actor-1")

    assert EditorSessionState.find("page", "doc-1", "someone-else") == :error
  end

  test "the same actor's session on another document is not offered" do
    open!(resource_id: "doc-1", actor_id: "actor-1")

    assert EditorSessionState.find("page", "doc-2", "actor-1") == :error
    assert EditorSessionState.find("layout", "doc-1", "actor-1") == :error
  end

  # A master has no site and therefore no actor id on some paths; nil has to match nil rather than
  # matching everything or nothing.
  test "a session with no actor is found by no actor, and not by one" do
    open!(resource_id: "doc-1", actor_id: nil)

    assert {:ok, _found} = EditorSessionState.find("page", "doc-1", nil)
    assert EditorSessionState.find("page", "doc-1", "actor-1") == :error
  end

  test "the newest of several sessions on one document wins" do
    _older = open!(resource_id: "doc-1", actor_id: "actor-1")
    newer = open!(resource_id: "doc-1", actor_id: "actor-1")

    # `put/2` stamps `touched_at` from a monotonic clock, so the second open is the later one.
    EditorSessionState.put(newer.token, newer)

    assert {:ok, found} = EditorSessionState.find("page", "doc-1", "actor-1")
    assert found.token == newer.token
  end

  test "a row whose session vanished between the scan and the read is not a crash" do
    session = open!(resource_id: "doc-1", actor_id: "actor-1")
    EditorSessionState.delete(session.token)

    assert EditorSessionState.find("page", "doc-1", "actor-1") == :error
  end
end
