# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.HistoryTest do
  @moduledoc """
  The path from a gesture in the editor to a row somebody can read months later, and back again.

  The interesting cases are all about NOT writing the obvious thing: a drag that fires forty times
  is one row, a row flushed three times keeps one snapshot, and a change made before its draft
  existed still belongs to that draft once it does.
  """
  use MishkaCmsCore.DataCase
  use ExUnit.Case, async: false

  import MishkaCmsCore.Test.Factory

  alias MishkaCmsCore.Runtime.PageBuilder.{Drafts, EditorSession, History, Tree}
  alias MishkaCmsCore.Runtime.{PageBuilderEvent, PageBuilderSnapshot}

  require Ash.Query

  @moduletag :unit

  @template ~s(<div id="root"><h1>Contact Us</h1><p>Say hello</p></div>)

  setup do
    site = create_site!()
    page = create_page!(site_id: site.id)
    author = create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: site.id)

    {:ok, session} =
      EditorSession.open(%{
        section: "page",
        template: @template,
        site_id: site.id,
        resource_id: page.id
      })

    %{site: site, page: page, author: author, session: session, token: session.token}
  end

  defp rows(page) do
    PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(source_id == ^page.id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  end

  defp snapshots do
    PageBuilderSnapshot
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.read!(authorize?: false)
  end

  defp heading(session), do: Enum.find(Tree.walk(session.tree), &(&1.tag == "h1"))

  defp heading_or_para(session),
    do: Enum.find(Tree.walk(session.tree), &(&1.tag in ["h1", "p"]))

  defp html(session),
    do: MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer.serialize(session.tree)

  # The editor has ONE mutation funnel, so the tests go through it rather than around it: a helper
  # that wrote rows directly would pass while the real path was broken.
  defp text_edit(token, %{id: id}, text), do: text_edit(token, id, text)

  defp text_edit(token, id, text) when is_binary(id),
    do: EditorSession.apply_op(token, %{kind: :set_text, node_id: id, text: text})

  defp style_edit(token, id, prop, value),
    do:
      EditorSession.apply_op(token, %{
        kind: :set_style,
        node_id: id,
        bucket: :base,
        prop: prop,
        value: value
      })

  describe "flush/2" do
    test "somebody with no say over the site writes nothing, and it is not silent", context do
      nobody = create_user!(site_id: context.site.id)
      {:ok, _} = text_edit(context.token, heading(context.session), "Talk to us")

      assert {:error, {:partial, 0}} = History.flush(context.token, nobody)
      assert rows(context.page) == []

      # Put back rather than dropped, so the next flush by somebody who may write still records it.
      assert {:ok, 1} = History.flush(context.token, context.author)
      assert length(rows(context.page)) == 1
    end

    test "writes what the session has queued and nothing else", context do
      {:ok, _} = text_edit(context.token, heading(context.session), "Talk to us")

      assert {:ok, 1} = History.flush(context.token, context.author)

      assert [row] = rows(context.page)
      assert row.op == :set_text
      assert row.kind == :content
      assert row.author_id == context.author.id
      assert row.site_id == context.site.id
      assert row.source_type == :page
    end

    test "a second flush with nothing queued writes nothing", context do
      {:ok, _} = text_edit(context.token, heading(context.session), "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      assert {:ok, 0} = History.flush(context.token, context.author)
      assert length(rows(context.page)) == 1
    end

    test "one gesture is one row, however many times it fires", context do
      id = heading(context.session).id

      for size <- ["40px", "42px", "44px", "46px", "48px"] do
        {:ok, _} =
          style_edit(context.token, id, "font-size", size)
      end

      {:ok, _written} = History.flush(context.token, context.author)

      assert [row] = rows(context.page)
      assert row.detail =~ "48px"
    end

    test "two different properties are two rows", context do
      id = heading(context.session).id

      {:ok, _} = style_edit(context.token, id, "padding", "14px")
      {:ok, _} = style_edit(context.token, id, "gap", "20px")

      {:ok, _} = History.flush(context.token, context.author)

      assert length(rows(context.page)) == 2
    end

    test "a settling gesture keeps one snapshot, not one per flush", context do
      id = heading(context.session).id

      # Flushed between each step, which is what the editor does while a value is still moving.
      for size <- ["40px", "44px", "48px"] do
        {:ok, _} =
          style_edit(context.token, id, "font-size", size)

        {:ok, _} = History.flush(context.token, context.author)
      end

      assert [row] = rows(context.page)
      assert length(snapshots()) == 1
      assert row.snapshot_id == hd(snapshots()).id
    end
  end

  # ONE PROMPT IS A HUNDRED EDITS NOBODY MADE BY HAND, which makes it the change least
  # reconstructible from memory and the worst one to leave without a way back. So the assistant's
  # rows are allowed a document four times the size before a snapshot is refused.
  describe "how big a document a restore point is kept for" do
    # 1.6 MB in three nodes: past the general cap, under the assistant's, and cheap to parse — a
    # document that reached the size the honest way would take seconds to build in a test.
    @oversized ~s(<div id="root"><p>) <>
                 String.duplicate("lorem ipsum dolor ", 90_000) <> ~s(</p></div>)

    setup context do
      {:ok, session} =
        EditorSession.open(%{
          section: "page",
          template: @oversized,
          site_id: context.site.id,
          resource_id: context.page.id
        })

      %{session: session, token: session.token}
    end

    test "a person's change on an oversized document keeps the row and refuses the payload",
         context do
      {:ok, _} = text_edit(context.token, heading_or_para(context.session), "changed")
      {:ok, 1} = History.flush(context.token, context.author)

      assert [row] = rows(context.page)
      assert row.refused
      refute row.snapshot_id
      assert row.author_type == :human
      assert snapshots() == []
    end

    test "the assistant's change on the same document keeps its restore point", context do
      {:ok, _} =
        EditorSession.apply_ops(
          context.token,
          [%{kind: :set_text, node_id: heading_or_para(context.session).id, text: "rewritten"}],
          "Rewrote the copy",
          author_type: :ai,
          note: "Tightened the paragraph.",
          prompt: "make this shorter",
          backend: "claude-opus-5"
        )

      {:ok, 1} = History.flush(context.token, context.author)

      assert [row] = rows(context.page)
      refute row.refused
      assert row.snapshot_id
      assert row.author_type == :ai
      assert row.prompt == "make this shorter"
      assert row.backend == "claude-opus-5"
      assert row.note == "Tightened the paragraph."
    end

    test "and that restore point still restores", context do
      {:ok, _} =
        EditorSession.apply_ops(
          context.token,
          [%{kind: :set_text, node_id: heading_or_para(context.session).id, text: "rewritten"}],
          "Rewrote the copy",
          author_type: :ai
        )

      {:ok, 1} = History.flush(context.token, context.author)
      [row] = rows(context.page)

      assert {:ok, session} = History.revert(context.token, row.id, context.author)
      refute html(session) =~ "rewritten"
      assert html(session) =~ "lorem ipsum"
    end
  end

  # WHICH PILL A CHANGE APPEARS UNDER. The rule named two kinds that can never be minted —
  # `:paste_styles`, which reaches the log as a run, and `:redo`, because a step row is minted as
  # `:undo` in both directions — and missed the one that is minted constantly. So every run fell
  # through to Content: a bulk delete, a duplicate, a find-and-replace, an assistant restyling forty
  # elements, and pasting styles itself.
  describe "which bucket a change files under" do
    test "a single style edit is style, and a single text edit is content", context do
      id = heading(context.session).id

      {:ok, _} = style_edit(context.token, id, "padding", "14px")
      {:ok, 1} = History.flush(context.token, context.author)
      assert [%{kind: :style}] = rows(context.page)

      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)
      assert [%{kind: :content} | _rest] = rows(context.page)
    end

    test "a run that says it was styling files under style", context do
      {:ok, _} =
        EditorSession.apply_ops(
          context.token,
          [
            %{
              kind: :set_style,
              node_id: heading(context.session).id,
              bucket: :base,
              prop: "gap",
              value: "8px"
            }
          ],
          "paste styles",
          bucket: :style
        )

      {:ok, 1} = History.flush(context.token, context.author)

      assert [%{kind: :style}] = rows(context.page)
    end

    test "pasting styles onto many elements files under style, like pasting onto one", context do
      ids =
        context.session.tree
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :tag))
        |> Enum.take(2)
        |> Enum.map(& &1.id)

      # There has to be something to copy: an empty look pastes no ops and records nothing.
      {:ok, _} = style_edit(context.token, hd(ids), "padding", "12px")
      {:ok, _} = EditorSession.copy_styles(context.token, hd(ids))
      {:ok, _} = EditorSession.select(context.token, hd(ids))
      {:ok, _} = EditorSession.mark(context.token, List.last(ids))
      {:ok, _} = EditorSession.bulk(context.token, "paste_styles")
      {:ok, _} = History.flush(context.token, context.author)

      assert [%{kind: :style}] = rows(context.page)
    end

    test "a run that says nothing is content, as it always was", context do
      {:ok, _} =
        EditorSession.apply_ops(
          context.token,
          [%{kind: :duplicate, node_id: heading(context.session).id}],
          "duplicate"
        )

      {:ok, 1} = History.flush(context.token, context.author)

      assert [%{kind: :content}] = rows(context.page)
    end

    test "the ops that read as a step through the document agree with the timeline", context do
      assert History.publish_op?(:restore)
      assert History.publish_op?(:undo)
      assert History.publish_op?(:publish)

      refute History.publish_op?(:set_style)
      refute History.publish_op?(:run)

      # These two were in the rule and can never be minted, so they said nothing true about any row.
      refute History.publish_op?(:redo)
      refute History.publish_op?(:paste_styles)
      assert context.page
    end
  end

  # FIVE TAPS ARE ONE ROW. A run of undos is one change to the record — "net movement: 5 back" — not
  # five rows saying one each. The run used to be looked for in the pending buffer, which every
  # change flushes and drains, so by the second tap the first had already been written and the run
  # could never form: the timeline filled with a row per keypress.
  describe "a run of undos" do
    test "is one row, however many taps it took", context do
      id = heading(context.session).id

      for value <- ["10px", "12px", "14px"] do
        {:ok, _} = style_edit(context.token, id, "padding-#{value}", value)
      end

      {:ok, _} = History.flush(context.token, context.author)
      before = length(rows(context.page))

      for _tap <- 1..3 do
        {:ok, _} = EditorSession.undo(context.token)
        {:ok, _} = History.flush(context.token, context.author)
      end

      steps = Enum.filter(rows(context.page), &(&1.op == :undo))

      assert length(steps) == 1, "three taps wrote #{length(steps)} rows"
      assert hd(steps).label =~ "3 changes"
      assert length(rows(context.page)) == before + 1
    end

    test "and going back and forward again says so", context do
      id = heading(context.session).id
      {:ok, _} = style_edit(context.token, id, "padding", "10px")
      {:ok, _} = History.flush(context.token, context.author)

      {:ok, _} = EditorSession.undo(context.token)
      {:ok, _} = History.flush(context.token, context.author)
      {:ok, _} = EditorSession.redo(context.token)
      {:ok, _} = History.flush(context.token, context.author)

      assert [step] = Enum.filter(rows(context.page), &(&1.op == :undo))
      assert step.detail =~ "none"
    end

    test "a real edit ends the run, so the next taps are their own row", context do
      id = heading(context.session).id
      {:ok, _} = style_edit(context.token, id, "padding", "10px")
      {:ok, _} = style_edit(context.token, id, "gap", "8px")
      {:ok, _} = History.flush(context.token, context.author)

      {:ok, _} = EditorSession.undo(context.token)
      {:ok, _} = History.flush(context.token, context.author)

      {:ok, _} = style_edit(context.token, id, "margin", "4px")
      {:ok, _} = History.flush(context.token, context.author)

      {:ok, _} = EditorSession.undo(context.token)
      {:ok, _} = History.flush(context.token, context.author)

      assert length(Enum.filter(rows(context.page), &(&1.op == :undo))) == 2
    end
  end

  describe "reverting" do
    test "puts the document back and says so in the record", context do
      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      [row] = rows(context.page)

      assert {:ok, session} = History.revert(context.token, row.id, context.author)

      # By the document, not by node id: a snapshot is HEEx, and parsing it back mints fresh ids,
      # so the element that was edited is no longer reachable by the id it had.
      assert html(session) =~ "Contact Us"
      refute html(session) =~ "Talk to us"
      refute Tree.get(session.tree, id)
    end

    test "the revert is itself recorded", context do
      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)
      [row] = rows(context.page)

      {:ok, _} = History.revert(context.token, row.id, context.author)
      {:ok, 1} = History.flush(context.token, context.author)

      assert [restore | _] = rows(context.page)
      assert restore.op == :restore
      assert restore.kind == :publish
      assert restore.author_id == context.author.id
    end

    # WHAT YOU WERE WORKING ON IS STILL WHAT YOU ARE WORKING ON. A snapshot is HEEx, so restoring it
    # re-parses the document and mints new node ids; matching the selection on the old one found
    # nothing, and every revert deselected whatever the author had in the inspector.
    test "the selection survives, so the inspector does not empty itself", context do
      id = heading(context.session).id
      {:ok, _} = EditorSession.select(context.token, id)
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      [row] = rows(context.page)

      assert {:ok, session} = History.revert(context.token, row.id, context.author)

      refute session.selection == id, "the id did not change; this proves nothing"
      assert Tree.get(session.tree, session.selection).tag == "h1"
    end

    test "a row whose payload is gone is reported, not raised", context do
      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)
      [row] = rows(context.page)

      Enum.each(snapshots(), &Ash.destroy!(&1, authorize?: false))

      assert {:error, :gone} = History.revert(context.token, row.id, context.author)
    end
  end

  # A REVERT PUTS ANOTHER DOCUMENT INTO THIS EDITOR, so the row it reads must be this document's own.
  # The row id arrives from the browser; the session is what says which document is open.
  describe "which rows a revert may read" do
    setup _context do
      other_site = create_site!()
      other_page = create_page!(site_id: other_site.id)

      other_author =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: other_site.id)

      {:ok, other_session} =
        EditorSession.open(%{
          section: "page",
          template: ~s(<div id="root"><h1>SECRET-OF-SITE-B</h1></div>),
          site_id: other_site.id,
          resource_id: other_page.id
        })

      {:ok, _} = text_edit(other_session.token, heading(other_session), "Still secret")
      {:ok, 1} = History.flush(other_session.token, other_author)
      [their_row] = rows(other_page)

      %{their_row: their_row, other_page: other_page}
    end

    test "never another site's row, even for a site user holding every permission", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      for actor <- [context.author, star] do
        assert {:error, :gone} = History.revert(context.token, context.their_row.id, actor)
      end

      {:ok, session} = EditorSession.fetch(context.token)
      refute html(session) =~ "SECRET-OF-SITE-B"
    end

    test "never another document's row on the same site", context do
      sibling = create_page!(site_id: context.site.id)

      {:ok, sibling_session} =
        EditorSession.open(%{
          section: "page",
          template: ~s(<div id="root"><h1>The sibling</h1></div>),
          site_id: context.site.id,
          resource_id: sibling.id
        })

      {:ok, _} = text_edit(sibling_session.token, heading(sibling_session), "Sibling edit")
      {:ok, 1} = History.flush(sibling_session.token, context.author)
      [sibling_row] = rows(sibling)

      assert {:error, :gone} = History.revert(context.token, sibling_row.id, context.author)
    end

    test "a master reverts a site's document from the document's own rows", context do
      master = create_user_with_permissions!(["*"])
      {:ok, _} = text_edit(context.token, heading(context.session), "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)
      [row] = rows(context.page)

      assert {:ok, session} = History.revert(context.token, row.id, master)
      assert html(session) =~ "Contact Us"
    end

    test "no user reverts nothing", context do
      {:ok, _} = text_edit(context.token, heading(context.session), "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)
      [row] = rows(context.page)

      assert {:error, :gone} = History.revert(context.token, row.id, nil)
    end

    test "clearing another site's document removes nothing of it", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      assert {:ok, 0} = History.clear(:page, context.other_page.id, star)
      assert [_kept] = rows(context.other_page)
    end
  end

  # A SNAPSHOT HAS NO SITE OF ITS OWN, so it is reached through the row that points at it. Read on its
  # own, it is any site's document.
  describe "who reaches a snapshot directly" do
    setup context do
      {:ok, _} = text_edit(context.token, heading(context.session), "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)
      [snapshot] = snapshots()

      %{snapshot: snapshot}
    end

    test "a site user reads none, even holding every permission", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      assert {:ok, []} = Ash.read(PageBuilderSnapshot, actor: star)
    end

    test "a site user deletes none", context do
      star = create_user_with_permissions!(["*"], site_id: context.site.id)

      assert {:error, _refused} = Ash.destroy(context.snapshot, actor: star)
      assert length(snapshots()) == 1
    end

    test "a master reads them", context do
      master = create_user_with_permissions!(["*"])

      assert {:ok, [%{id: id}]} = Ash.read(PageBuilderSnapshot, actor: master)
      assert id == context.snapshot.id
    end
  end

  describe "adopt_draft/3" do
    test "attaches this sitting's changes to the draft that now holds them", context do
      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      assert [%{draft_id: nil}] = rows(context.page)

      draft = draft_for(context.page)
      assert {:ok, 1} = History.adopt_draft(context.token, draft.id, context.author)

      assert [%{draft_id: adopted}] = rows(context.page)
      assert adopted == draft.id
    end

    test "leaves changes made before this sitting where they are", context do
      older =
        PageBuilderEvent
        |> Ash.Changeset.for_create(
          :create,
          %{
            id: Ecto.UUID.generate(),
            source_type: :page,
            source_id: context.page.id,
            site_id: context.site.id,
            label: "Last week's work",
            kind: :style,
            op: :set_style,
            inserted_at: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
          },
          tenant: context.site.id,
          authorize?: false
        )
        |> Ash.create!(authorize?: false)

      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      draft = draft_for(context.page)
      {:ok, _} = History.adopt_draft(context.token, draft.id, context.author)

      untouched = Enum.find(rows(context.page), &(&1.id == older.id))
      assert untouched.draft_id == nil
    end
  end

  describe "collect/5" do
    test "a publish drops the payloads and keeps the record", context do
      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      assert length(snapshots()) == 1

      assert {:ok, %{dropped: 1}} =
               History.collect(
                 :page,
                 context.page.id,
                 nil,
                 %{
                   site_id: context.site.id,
                   label: "Published contact",
                   detail: "9 elements live"
                 },
                 context.author
               )

      assert snapshots() == []

      # The rows survive: who changed what is the thing a record exists for, and a publish is
      # exactly the moment it matters.
      kept = rows(context.page)
      assert length(kept) == 2
      assert Enum.all?(kept, &is_nil(&1.snapshot_id))
      assert Enum.any?(kept, &(&1.op == :publish and &1.author_type == :system))
    end

    test "running it twice is not an error", context do
      summary = %{site_id: context.site.id, label: "Published contact"}

      {:ok, %{dropped: 0}} = History.collect(:page, context.page.id, nil, summary, context.author)

      assert {:ok, %{dropped: 0}} =
               History.collect(:page, context.page.id, nil, summary, context.author)
    end

    test "a publish from a draft takes that branch's payloads too", context do
      draft = drafted(context)

      assert {:ok, %{dropped: 1}} = collect(context, draft.id)
      assert snapshots() == []
    end

    # THE ORDER A PUBLISH REALLY RUNS IN, and the one nothing used to exercise. Discarding the spent
    # draft releases its rows onto the live branch before the collect asks for them, so a collect
    # scoped to the draft alone matched nothing and left every payload behind — on the ORDINARY
    # publish, because autosave mints a draft before the author ever reaches the button.
    test "and still takes them once the publish has released the draft", context do
      draft = drafted(context)
      publisher = create_user_with_permissions!(["*"], site_id: context.site.id)
      :ok = Drafts.discard("page", draft.id, publisher)

      assert [%{draft_id: nil, snapshot_id: held}] = rows(context.page)
      assert held, "the row kept no payload; this proves nothing"

      assert {:ok, %{dropped: 1}} = collect(context, draft.id)
      assert snapshots() == []
      assert Enum.all?(rows(context.page), &is_nil(&1.snapshot_id))
    end

    # And the reason this is not simply "every row on the anchor": a colleague's draft is its own
    # branch, still open, and reverting into it is exactly what they have not published away.
    test "and leaves a draft nobody published alone", context do
      {:ok, other} =
        EditorSession.open(%{
          section: "page",
          template: @template,
          site_id: context.site.id,
          resource_id: context.page.id
        })

      {:ok, _} = text_edit(other.token, heading(other), "Somebody else's afternoon")
      {:ok, 1} = History.flush(other.token, context.author)
      {:ok, 1} = History.adopt_draft(other.token, draft_for(context.page).id, context.author)

      mine = drafted(context)

      assert {:ok, %{dropped: 1}} = collect(context, mine.id)
      assert length(snapshots()) == 1
    end

    # THE PUBLISH ROW IS WRITTEN FIRST, and this is the half of that which can be asserted: a collect
    # that cannot write the row throws no payload away either, so the next publish still has
    # something to collect and the timeline never holds rows that lost their Restore for no stated
    # reason. The same order is what makes the job survivable — it runs in a task the LiveView is
    # linked to, so leaving the builder kills it mid-sweep, and dropped payloads the next publish
    # takes anyway where that row would be gone for good.
    #
    # A holder of ANOTHER type's area: the page's history is not theirs to write, so the publish
    # row is refused — the one actor that reaches the second half of this without the first.
    test "a collect that cannot write the publish row keeps the payloads", context do
      draft = drafted(context)

      reader =
        create_user_with_permissions!(["admin:dashboard:runtime:layout"],
          site_id: context.site.id
        )

      assert {:error, _refused} =
               History.collect(
                 :page,
                 context.page.id,
                 draft.id,
                 %{site_id: context.site.id, label: "Published contact"},
                 reader
               )

      assert snapshots() != []
      refute Enum.any?(rows(context.page), &(&1.op == :publish))
    end

    test "a publish leaves a restore point another site's row still holds", context do
      other_site = create_site!()
      other_page = create_page!(site_id: other_site.id)

      other_author =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: other_site.id)

      {:ok, other_session} =
        EditorSession.open(%{
          section: "page",
          template: ~s(<div id="root"><h1>SECRET-OF-SITE-B</h1></div>),
          site_id: other_site.id,
          resource_id: other_page.id
        })

      {:ok, _} = text_edit(other_session.token, heading(other_session), "Still secret")
      {:ok, 1} = History.flush(other_session.token, other_author)
      [%{snapshot_id: theirs} = their_row] = rows(other_page)

      {:ok, _} = text_edit(context.token, heading(context.session), "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)
      [mine] = rows(context.page)
      point_at!(mine, theirs)

      assert {:ok, _collected} = collect(context, nil)

      assert Enum.any?(snapshots(), &(&1.id == theirs))
      assert [%{id: id, snapshot_id: ^theirs}] = rows(other_page)
      assert id == their_row.id
    end
  end

  # HOWEVER A ROW CAME TO NAME A PAYLOAD it did not mint — seeds share one across a page's rows — the
  # publish that collects it must not take it from under another row.
  defp point_at!(row, snapshot_id) do
    MishkaCmsCore.Repo.query!(
      "UPDATE page_builder_events SET snapshot_id = $1 WHERE id = $2",
      [Ecto.UUID.dump!(snapshot_id), Ecto.UUID.dump!(row.id)]
    )
  end

  describe "clear/3 and the sweep" do
    test "clearing takes the whole anchor, rows and payloads", context do
      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      assert {:ok, 1} = History.clear(:page, context.page.id, context.author)
      assert rows(context.page) == []

      assert {:ok, 1} = History.sweep_orphan_snapshots()
      assert snapshots() == []
    end

    test "the sweep leaves payloads a row still points at", context do
      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      assert {:ok, 0} = History.sweep_orphan_snapshots()
      assert length(snapshots()) == 1
    end

    # THE SWEEP IS THE SYSTEM'S CHORE, not the publisher's: it looks at every site's rows to decide
    # what nothing points at, and a user sees only their own site's.
    test "the sweep keeps another site's payloads whoever published", _context do
      other_site = create_site!()
      other_page = create_page!(site_id: other_site.id)

      other_author =
        create_user_with_permissions!(["admin:dashboard:runtime:page"], site_id: other_site.id)

      {:ok, other_session} =
        EditorSession.open(%{
          section: "page",
          template: @template,
          site_id: other_site.id,
          resource_id: other_page.id
        })

      {:ok, _} = text_edit(other_session.token, heading(other_session), "Elsewhere")
      {:ok, 1} = History.flush(other_session.token, other_author)
      [%{snapshot_id: kept}] = rows(other_page)

      assert {:ok, 0} = History.sweep_orphan_snapshots()
      assert Enum.any?(snapshots(), &(&1.id == kept))
    end

    test "clearing one page leaves another's alone", context do
      other = create_page!(site_id: context.site.id)

      {:ok, other_session} =
        EditorSession.open(%{
          section: "page",
          template: @template,
          site_id: context.site.id,
          resource_id: other.id
        })

      {:ok, _} =
        text_edit(other_session.token, heading(other_session), "Elsewhere")

      {:ok, 1} = History.flush(other_session.token, context.author)

      id = heading(context.session).id
      {:ok, _} = text_edit(context.token, id, "Talk to us")
      {:ok, 1} = History.flush(context.token, context.author)

      {:ok, 1} = History.clear(:page, context.page.id, context.author)

      assert rows(context.page) == []
      assert length(rows(other)) == 1
    end
  end

  # One recorded change sitting on a draft branch, made the way a sitting really makes one: the
  # change lands before the draft exists, and the autosave that creates it adopts what is there.
  defp drafted(context) do
    {:ok, _} = text_edit(context.token, heading(context.session), "Talk to us")
    {:ok, 1} = History.flush(context.token, context.author)

    draft = draft_for(context.page)
    {:ok, 1} = History.adopt_draft(context.token, draft.id, context.author)
    draft
  end

  defp collect(context, draft_id),
    do:
      History.collect(
        :page,
        context.page.id,
        draft_id,
        %{site_id: context.site.id, label: "Published contact"},
        context.author
      )

  defp draft_for(page) do
    nth = System.unique_integer([:positive])

    MishkaCmsCore.Runtime.PageDraft
    |> Ash.Changeset.for_create(
      :create,
      %{
        source_page_id: page.id,
        name: "Draft under test #{nth}",
        title: "Draft under test #{nth}",
        path: "/draft-under-test-#{nth}",
        template: @template
      },
      tenant: page.site_id,
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
