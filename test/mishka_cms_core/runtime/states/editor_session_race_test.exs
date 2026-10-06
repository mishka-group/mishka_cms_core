defmodule MishkaCmsCore.Runtime.States.EditorSessionRaceTest do
  @moduledoc """
  One session, more than one writer.

  The chrome, the canvas, and the tasks each of them starts — the history flush, the autosave, the
  palette load — all read a session, work out the next one and store it. Stored with a plain insert,
  whichever finished last put back everything it had read: a flush that drained the history queue a
  moment before an edit landed stored the session without that edit, after every screen had been
  told about it. The canvas then drew the page as it was, which is how this surfaced — the preview
  bar calling a layout a page, one run in many.

  A race is a matter of timing, so the tests that pin the rule do not wait for one. They land the
  second write INSIDE the first change, between its read and its write, on the first try only —
  which is exactly what another process doing it at the wrong moment looks like from there.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession
  alias MishkaCmsCore.Runtime.PageBuilder.Strict
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.States.EditorHistoryState
  alias MishkaCmsCore.Runtime.States.EditorSessionState
  alias MishkaCmsCore.Test.LandingCalendar

  @moduletag :unit

  setup do
    {:ok, session} =
      EditorSession.open(%{section: "page", template: ~s(<div id="root"><p>hello</p></div>)})

    on_exit(fn -> EditorSession.close(session.token) end)

    %{session: session, div: Enum.find(Tree.walk(session.tree), &(&1.tag == "div"))}
  end

  # THE FIRST CALL ONLY. A second write that landed on every try would be a change that can never
  # be stored, which is a different test.
  defp landing_once(write) do
    send(self(), :land)

    fn ->
      receive do
        :land -> write.()
      after
        0 -> :ok
      end
    end
  end

  defp set_attr(token, node, name) do
    {:ok, _session} =
      EditorSession.apply_op(token, %{kind: :set_attr, node_id: node.id, name: name, value: "1"})
  end

  describe "a write landing between a change's read and its write" do
    test "is kept, and the change is worked out again on the session it left", %{session: session} do
      land = landing_once(fn -> {:ok, _} = EditorSession.set_preview(session.token, true) end)

      assert {:ok, :stored} =
               EditorSessionState.update(session.token, fn stored ->
                 send(self(), {:read, stored.preview?})
                 land.()
                 {:write, %{stored | dir: "rtl"}, :stored}
               end)

      assert_received {:read, false}
      assert_received {:read, true}

      assert {:ok, %{preview?: true, dir: "rtl"}} = EditorSession.fetch(session.token)
    end

    test "an edit to the document is kept too", %{session: session, div: div} do
      land = landing_once(fn -> set_attr(session.token, div, "data-landed") end)

      assert {:ok, :stored} =
               EditorSessionState.update(session.token, fn stored ->
                 land.()
                 {:write, %{stored | preview?: true}, :stored}
               end)

      {:ok, stored} = EditorSession.fetch(session.token)

      assert stored.preview?
      assert Node.attr(Tree.get(stored.tree, div.id), "data-landed") == {:string, "1"}
      assert stored.revision == 1
      assert length(stored.past) == 1
    end

    test "a change that stores nothing leaves the row as it was", %{session: session} do
      assert {:ok, :nothing} =
               EditorSessionState.update(session.token, fn _ -> {:skip, :nothing} end)

      assert {:ok, ^session} = EditorSession.fetch(session.token)
    end

    test "a session that is not there is not written" do
      assert :error = EditorSessionState.update("nosuchsession", fn s -> {:write, s, :stored} end)
    end

    # A CHANGE THAT WRITES ITS OWN ROW EVERY TIME IT RUNS can never be stored, and retrying it for
    # ever would hang the process that asked.
    test "a change that writes its own row on every try is stopped", %{session: session} do
      assert_raise Strict.Violation, ~r/kept losing/, fn ->
        EditorSessionState.update(session.token, fn stored ->
          {:ok, _} = EditorSession.set_preview(session.token, !stored.preview?)
          {:write, stored, :stored}
        end)
      end
    end
  end

  # THE INTERLEAVING THAT WAS SEEN. `History.flush/2` runs in a task, off the LiveView process, and
  # drains the queue while the author goes on editing.
  #
  # The drain itself is the change that loses here. It sorts the queue by date between its read and
  # its write, so an entry put back dated on `LandingCalendar` lands the edit right there.
  describe "the history flush draining while an edit lands" do
    test "keeps the edit, and hands over each entry exactly once", %{session: session, div: div} do
      set_attr(session.token, div, "data-first")

      :ok =
        EditorSession.requeue(session.token, [%{id: "requeued", at: LandingCalendar.utc_now()}])

      LandingCalendar.land(fn -> set_attr(session.token, div, "data-second") end)

      assert {:ok, drained} = EditorSession.drain_pending(session.token)
      refute_received {LandingCalendar, :land, _write}

      {:ok, stored} = EditorSession.fetch(session.token)
      node = Tree.get(stored.tree, div.id)

      assert Node.attr(node, "data-first") == {:string, "1"}
      assert Node.attr(node, "data-second") == {:string, "1"}, "the drain put the edit back"

      assert Enum.sort(Enum.map(drained, & &1.id)) ==
               Enum.sort(["requeued" | Enum.map(stored.past, & &1.id)])

      assert stored.pending == %{}
      assert {:ok, []} = EditorSession.drain_pending(session.token)
    end
  end

  # SAID ONCE THE SESSION WITHOUT IT IS STORED. Reported before the swap, the violation left the
  # entry where it was, and the next Ctrl+Z met it again.
  describe "a history entry pointing at nothing" do
    test "is dropped before it is reported", %{session: session, div: div} do
      set_attr(session.token, div, "data-step")
      {:ok, %{past: [entry]}} = EditorSession.fetch(session.token)
      EditorHistoryState.delete(session.token, entry.ref)

      assert_raise Strict.Violation, ~r/pointed at nothing/, fn ->
        EditorSession.undo(session.token)
      end

      assert {:ok, %{past: []}} = EditorSession.fetch(session.token)
    end
  end

  # NOTHING HERE IS ARRANGED. Every writer is a real mutation racing the others, so what is asserted
  # is what no interleaving may break: every edit is in the document, every entry is handed to the
  # flush once, and a try that lost left no stored step behind.
  describe "many writers at once" do
    @editors 6
    @edits 30
    @requeued 40
    @rounds 5
    @taps 3

    test "lose nothing", %{session: session, div: div} do
      token = session.token

      editors =
        for editor <- 1..@editors do
          Task.async(fn ->
            for edit <- 1..@edits, do: set_attr(token, div, "data-e#{editor}-#{edit}")
          end)
        end

      requeued = for n <- 1..@requeued, do: %{id: "requeued-#{n}", at: DateTime.utc_now()}

      requeuer =
        Task.async(fn -> Enum.each(requeued, &(:ok = EditorSession.requeue(token, [&1]))) end)

      viewer =
        Task.async(fn ->
          for n <- 1..@edits, do: {:ok, _} = EditorSession.set_preview(token, rem(n, 2) == 0)
        end)

      flusher = Task.async(fn -> drain_until_stopped(token, []) end)

      Task.await_many([viewer, requeuer | editors], 10_000)
      send(flusher.pid, :stop)
      {:ok, last} = EditorSession.drain_pending(token)
      drained = Task.await(flusher, 10_000) ++ last

      {:ok, stored} = EditorSession.fetch(token)
      node = Tree.get(stored.tree, div.id)

      for editor <- 1..@editors, edit <- 1..@edits do
        assert Node.attr(node, "data-e#{editor}-#{edit}") == {:string, "1"},
               "the edit data-e#{editor}-#{edit} was lost"
      end

      assert stored.revision == @editors * @edits
      assert length(stored.past) == @editors * @edits

      ids = Enum.map(drained, & &1.id)
      assert length(ids) == length(Enum.uniq(ids)), "an entry was handed to the flush twice"

      assert MapSet.new(ids) ==
               MapSet.new(Enum.map(stored.past, & &1.id) ++ Enum.map(requeued, & &1.id))

      assert stored_steps(token) == length(stored.past)
      assert {:ok, _tree} = EditorSession.entry_tree(stored, List.last(stored.past))
    end

    # A STEP IS DELETED ONLY ONCE A SESSION WITHOUT IT IS STORED. Deleted any earlier, a change that
    # then lost its race would leave the stored session pointing at nothing, and the next undo to
    # reach it would find the step gone — which is a violation here, and a task that crashes.
    #
    # The first tap of a run keeps a whole document. First taps racing each other each keep one, and
    # only the one that lands belongs to the run; the rest must not stay behind. So every round
    # starts its taps together, and ends with a real edit, which ends the run — and the page is long
    # enough that keeping it takes long enough for the taps to overlap.
    test "undo and redo from several places at once keep every step, and nothing else" do
      {:ok, session} =
        EditorSession.open(%{
          section: "page",
          template: ~s(<div id="root">#{String.duplicate("<p>hello</p>", 400)}</div>)
        })

      on_exit(fn -> EditorSession.close(session.token) end)

      token = session.token
      div = Enum.find(Tree.walk(session.tree), &(&1.tag == "div"))
      for edit <- 1..@edits, do: set_attr(token, div, "data-step-#{edit}")

      for round <- 1..@rounds do
        steppers = for _stepper <- 1..@editors, do: Task.async(fn -> step_on_cue(token) end)

        Enum.each(steppers, &send(&1.pid, :go))
        Task.await_many(steppers, 10_000)
        set_attr(token, div, "data-round-#{round}")
      end

      {:ok, stored} = EditorSession.fetch(token)
      entries = stored.past ++ stored.future

      assert stored_steps(token) == length(entries) + @rounds,
             "a try that lost left a step behind"

      assert Enum.all?(entries, &match?({:ok, _tree}, EditorSession.entry_tree(stored, &1)))
    end
  end

  defp step_on_cue(token) do
    receive do
      :go ->
        for _tap <- 1..@taps do
          {:ok, _} = EditorSession.undo(token)
          {:ok, _} = EditorSession.redo(token)
        end
    end
  end

  defp drain_until_stopped(token, drained) do
    receive do
      :stop -> drained
    after
      0 ->
        {:ok, entries} = EditorSession.drain_pending(token)
        drain_until_stopped(token, drained ++ entries)
    end
  end

  # Counted straight off the table: a step written by a try that lost is referenced by nothing, so
  # nothing but the table can say it is there.
  defp stored_steps(token) do
    :ets.select_count(:mishka_builder_history, [
      {{{token, :"$1"}, :_, :_}, [{:is_reference, :"$1"}], [true]}
    ])
  end
end
