# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.History do
  @moduledoc """
  Turns the editor's settled entries into durable rows, and reads them back.

  The undo stack in `MishkaCmsCore.Runtime.PageBuilder.EditorSession` stays what Ctrl+Z walks — in
  memory, instant, gone with the session. This is the half that survives: what the history sheet
  reads, what a colleague on the same draft sees, and what records who made a change.

  ## The write is batched, off-process, and idempotent

  `EditorSession` mints an id when an entry settles, so a row is identifiable before it exists. The
  flush drains everything queued and upserts it — which means a write that times out after
  succeeding, and is retried, updates the row rather than growing a second one. It also means a
  coalescing gesture that has already been flushed is corrected in place: the entry keeps its id, so
  the finished slider value replaces the first tick's row.

  Nothing here may run on the LiveView process. Autosave learned that the hard way — a database round
  trip inline froze the editor for its duration, with every click and keystroke queued behind it.

  ## The snapshot

  Each row points at a `MishkaCmsCore.Runtime.PageBuilderSnapshot` holding gzipped HEEx: the document
  as it was BEFORE that change, so reverting to a row undoes it and everything after. A document past
  the snapshot threshold gets a row with no snapshot and `refused: true`, which the timeline says
  out loud rather than offering a Revert that cannot work.

  ## What it is anchored to

  `source_type` + `source_id` are the LIVE record, always. `draft_id` says which branch, and is `nil`
  for the editor's published stage — where nothing is written to the page but the work is still
  recorded, which is the whole reason that stage stopped meaning "lose it".
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.{EditorSession, Section, Strict, Tree}
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.{PageBuilderEvent, PageBuilderSnapshot}

  require Ash.Query
  require Logger
  require MishkaCmsCore.Runtime.PageBuilder.Strict

  # ONLY KINDS THAT CAN ACTUALLY OCCUR. These listed two that never do — `:paste_styles`, which
  # reaches the log as a run, and `:redo`, because a step row is minted as `:undo` in both
  # directions — while the kind that DOES occur constantly, `:run`, was in neither and fell through
  # to content. So every bulk delete, every duplicate, every find-and-replace and every restyle an
  # assistant made filed under Content, and the Style pill did not show them.
  @style_ops [:set_style, :reset_styles]
  @publish_ops [:restore, :undo, :publish]

  @doc """
  Write everything the session has queued, and return how many rows landed.

  Runs in a task, not on the LiveView. On failure the entries are put back, so the next flush retries
  them and a flaky connection costs nothing but a delay.
  """
  @spec flush(String.t(), map() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def flush(token, actor) do
    with {:ok, entries} <- EditorSession.drain_pending(token),
         {:ok, session} <- EditorSession.fetch(token) do
      write_all(token, session, entries, actor)
    end
  end

  defp write_all(_token, _session, [], _actor), do: {:ok, 0}

  defp write_all(token, session, entries, actor) do
    # ONE ATTEMPT PER ENTRY. Counting failures by running the write a second time would write every
    # successful row twice — and with an upsert that is invisible until you read the timestamps.
    {ok, failed} =
      entries
      |> Enum.map(&{&1, write(session, &1, actor)})
      |> Enum.split_with(fn {_entry, result} -> result == :ok end)

    case failed do
      [] ->
        {:ok, length(ok)}

      _some ->
        EditorSession.requeue(token, Enum.map(failed, &elem(&1, 0)))
        {:error, {:partial, length(ok)}}
    end
  end

  defp write(session, entry, actor) do
    # The document as it was BEFORE this change, resolved once: whether a snapshot was taken and
    # whether it was refused for size are two answers to the same question.
    #
    # AND ONLY ONCE PER ROW. A coalescing gesture is re-queued on every op it absorbs, so the same
    # id is flushed several times as the value settles; minting a snapshot each time left the row
    # pointing at the newest and the earlier ones orphaned — measured at three 1.7 kB snapshots for
    # one padding drag. The tree is the same one every time, so the first is the right one to keep.
    {snapshot_id, refused?} =
      case existing_snapshot(entry.id, actor) do
        nil -> snapshot(session, entry, actor)
        found -> {found, false}
      end

    attrs =
      entry
      |> row_attrs(session)
      |> Map.put(:refused, refused?)

    PageBuilderEvent
    |> Ash.Changeset.for_create(:create, attrs,
      tenant: session.site_id,
      actor: actor,
      private_arguments: %{snapshot_id: snapshot_id}
    )
    |> Ash.create()
    |> case do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        # NEVER SILENT. The caller puts the entry back and retries, but a write that keeps failing
        # for a reason nobody can see is how a history quietly stops being one.
        Logger.warning("[PageBuilder.History] could not record a change: #{inspect(reason)}")
        :error
    end
  end

  defp row_attrs(entry, session) do
    %{
      id: entry.id,
      source_type: Section.to_atom!(session.section),
      source_id: session.resource_id,
      draft_id: session.draft_id,
      site_id: session.site_id,
      label: truncate(entry.label, 160) || gettext_noop("Change"),
      kind: bucket(entry),
      op: entry.kind,
      target: truncate(entry[:target], 120),
      detail: truncate(entry[:detail], 240),
      note: truncate(entry[:note], 500),
      author_type: entry[:author_type] || :human,
      prompt: truncate(entry[:prompt], 500),
      backend: truncate(entry[:backend], 80),
      inserted_at: entry[:at] || DateTime.utc_now()
    }
  end

  # THE BUCKET IS STORED, not derived at read time. The op lists below WILL drift as the editor grows
  # ops, and a row written last month must keep the bucket it was filed under — otherwise the pills
  # quietly re-sort history every time someone adds an operation.
  # A RUN SAYS WHAT IT WAS. One entry can stand for forty ops, so the only thing that knows whether
  # it was styling or content is whatever asked for it — `EditorSession.apply_ops/4` carries it here.
  defp bucket(%{bucket: bucket}) when bucket in [:content, :style, :publish], do: bucket
  defp bucket(%{kind: kind}) when kind in @style_ops, do: :style
  defp bucket(%{kind: kind}) when kind in @publish_ops, do: :publish
  defp bucket(_entry), do: :content

  @doc """
  Whether an op reads as a step through the document rather than a change to it.

  The timeline shows these by their own name — RESTORE, UNDO, PUBLISH — instead of the bucket they
  file under, so it asks here rather than keeping a fourth list of its own.
  """
  @spec publish_op?(atom()) :: boolean()
  def publish_op?(op), do: op in @publish_ops

  # `{snapshot_id, refused?}`. Refused means the document was past the size a snapshot is kept of —
  # told apart from "no tree any more", because the timeline says a different thing for each.
  # The size a snapshot is refused at depends on WHO made the change: the assistant's rows are worth
  # more than everybody else's, because one prompt is a hundred edits nobody made by hand.
  defp snapshot(session, entry, actor) do
    with {:ok, tree} <- EditorSession.entry_tree(session, entry),
         {:ok, heex} <- Serializer.to_heex(tree) do
      heex
      |> PageBuilderSnapshot.compress(PageBuilderSnapshot.max_bytes(entry[:author_type]))
      |> store_snapshot(actor)
    else
      _no_tree -> {nil, false}
    end
  end

  # What this row already points at, if it has been written before.
  defp existing_snapshot(id, actor) do
    with {:ok, query} <- rows_query(actor),
         {:ok, %{snapshot_id: snapshot_id}} <-
           query
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.select([:snapshot_id])
           |> Ash.read_one(actor: actor) do
      snapshot_id
    else
      _none -> nil
    end
  end

  # WHOSE ROWS A CALL MAY READ, decided by who is asking and never by what they ask for. A master
  # (`site_id` nil) reads across sites; a site user reads its own site's rows through the tenant
  # read, whatever permission it holds; anybody else reads nothing. Every read below starts here.
  defp rows_query(%{site_id: nil} = actor),
    do: {:ok, Ash.Query.for_read(PageBuilderEvent, :read_any, %{}, actor: actor)}

  defp rows_query(%{site_id: site_id} = actor) when is_binary(site_id),
    do: {:ok, Ash.Query.for_read(PageBuilderEvent, :read, %{}, actor: actor, tenant: site_id)}

  defp rows_query(_nobody), do: :error

  defp store_snapshot(:too_large, _actor), do: {nil, true}

  defp store_snapshot({:ok, payload, size}, actor) do
    PageBuilderSnapshot
    |> Ash.Changeset.for_create(:create, %{payload: payload, byte_size: size}, actor: actor)
    |> Ash.create()
    |> case do
      {:ok, row} ->
        {row.id, false}

      # A FAILED WRITE IS NOT RETENTION. Both leave a row with no payload, and the timeline reads
      # that one shape as "older than this page keeps documents for" — which, seconds after a write
      # that failed, is simply untrue. It is told apart by being said out loud: the row still records
      # what happened and who did it, and the reader is not given a reason that did not happen.
      {:error, reason} ->
        refused_snapshot(reason)
        {nil, false}
    end
  end

  # A REFUSAL IS NOT A FAILURE. Somebody who may not write to this site is answered by the policy,
  # which is the system working; the flush reports it and puts the entry back. Anything else is a
  # write that was allowed and did not happen, and in development that is worth stopping for.
  defp refused_snapshot(%Ash.Error.Forbidden{} = reason) do
    Logger.info("[PageBuilder.History] a restore point was not permitted: #{inspect(reason)}")
  end

  defp refused_snapshot(reason) do
    Strict.violation!("History.store_snapshot/2", "a restore point could not be written")
    Logger.warning("[PageBuilder.History] could not keep a restore point: #{inspect(reason)}")
  end

  @doc """
  Give this sitting's un-drafted rows to the draft that has just been created for it.

  The editor makes a draft LAZILY — it is named and written on the first autosave, not when the
  editor opens — so the first changes of a session are recorded before there is a draft to attach
  them to. Left alone they stay on the live record's timeline while their siblings sit on the
  draft's, which splits one afternoon's work across two lists for a reason nobody could infer.

  Bounded by the session's own start, so it can only ever adopt what this sitting wrote, and only
  when the editor is on the draft stage: rows written in published stage genuinely belong to no
  draft, and that is the point of recording them.
  """
  @spec adopt_draft(String.t(), String.t(), map() | nil) :: {:ok, non_neg_integer()} | :error
  def adopt_draft(token, draft_id, actor) when is_binary(draft_id) do
    with {:ok, %{stage: :draft} = session} <- EditorSession.fetch(token),
         false <- is_nil(session.opened_at),
         {:ok, query} <- rows_query(actor) do
      query
      |> Ash.Query.filter(
        source_type == ^Section.to_atom!(session.section) and
          source_id == ^session.resource_id and
          is_nil(draft_id) and
          inserted_at >= ^session.opened_at
      )
      |> Ash.read(actor: actor)
      |> case do
        {:ok, rows} ->
          Enum.each(rows, fn row ->
            row
            |> Ash.Changeset.for_update(:adopt_draft, %{draft_id: draft_id},
              tenant: session.site_id,
              actor: actor
            )
            |> Ash.update()
          end)

          {:ok, length(rows)}

        _error ->
          :error
      end
    else
      _not_a_draft_session -> {:ok, 0}
    end
  end

  def adopt_draft(_token, _draft_id, _actor), do: {:ok, 0}

  @doc """
  Restore the document a row was taken before, into the live editor session.

  Forward-only: `EditorSession.put_tree/3` pushes a "Restored" entry whose own ref holds the tree
  being left, so an undo immediately afterwards takes you back. Nothing is deleted.

  The snapshot is self-sufficient, which is why this works for a row written by a colleague, by the
  assistant, or last week — there is no in-memory ref to consult, and that is the whole reason
  snapshots were chosen over replaying a log of inverse operations.
  """
  @spec revert(String.t(), String.t(), map() | nil) ::
          {:ok, term()} | {:error, :gone | :unreadable | term()}
  def revert(token, row_id, actor) do
    with {:ok, session} <- open_session(token),
         {:ok, row} <- fetch_row(session, row_id, actor),
         {:ok, snapshot} <- fetch_snapshot(row, actor),
         {:ok, heex} <- PageBuilderSnapshot.decompress(snapshot.payload),
         {:ok, tree} <- Tree.parse(heex) do
      EditorSession.put_tree(token, tree, reason: :revert)
    end
  end

  defp open_session(token) do
    case EditorSession.fetch(token) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, :gone}
    end
  end

  # THE ROW MUST BE THIS DOCUMENT'S. Its id comes from the browser, so the session — not the id — says
  # which document is open, and a row of any other document, on this site or another, is not there.
  defp fetch_row(session, row_id, actor) do
    with {:ok, query} <- rows_query(actor),
         {:ok, %{} = row} <-
           query
           |> Ash.Query.filter(
             id == ^row_id and source_type == ^Section.to_atom!(session.section) and
               source_id == ^session.resource_id
           )
           |> Ash.Query.load([:snapshot])
           |> Ash.read_one(actor: actor) do
      {:ok, row}
    else
      :error -> {:error, :gone}
      {:ok, nil} -> {:error, :gone}
      error -> error
    end
  end

  defp fetch_snapshot(%{snapshot: %{payload: _} = snapshot}, _actor), do: {:ok, snapshot}
  defp fetch_snapshot(_row, _actor), do: {:error, :gone}

  @doc """
  What a publish leaves behind: the snapshots go, the rows stay, and one summary row is written.

  Costed rather than chosen. A snapshot is ~1.3 kB against a row's 122 B, so the payloads are 91% of
  the weight — and the rows are the per-author record this whole thing exists for. Deleting them at
  publish would erase who wrote what at the exact moment the work shipped.

  What is given up is reverting INTO the middle of a shipped draft, which nobody wants: the published
  state is right there, and the summary row is itself a revert point.

  Idempotent, so a retried job that finds the payloads already gone still succeeds — and it does not
  care whether the draft it is collecting still exists, which is what makes it safe to call at any
  point of a publish.

  THE SUMMARY ROW GOES FIRST, because it is the only half nothing writes later. This runs in a task
  the LiveView is linked to, so an author who publishes and leaves the builder in the same breath
  kills it in the middle of the sweep — and a sweep that dies half done costs weight the next publish
  takes anyway, where the row saying the page was published would be gone for good. It is read back
  by the query below and carries no payload, so it sweeps nothing of its own.
  """
  @spec collect(atom(), String.t(), String.t() | nil, map(), map() | nil) ::
          {:ok, %{dropped: non_neg_integer()}} | {:error, term()}
  def collect(source_type, source_id, draft_id, summary, actor) do
    with {:ok, _summary_row} <- write_summary(source_type, source_id, summary, actor),
         {:ok, rows} <- anchored_rows(source_type, source_id, draft_id, actor) do
      {:ok, %{dropped: drop_snapshots(rows)}}
    end
  end

  # THE SAME BRANCH RULE `PageBuilderEvent`'s `:for_anchor` READS BY — a draft is the live record's
  # rows plus its own — and here it is also what makes the collect independent of the publish's own
  # order. Publishing deletes the draft, and that destroy's `ReleaseBuilderHistory` sets `draft_id`
  # to nil on every row it held, so by the time this runs the rows it must collect have moved to the
  # live branch. Asking for the draft alone matched nothing and dropped ZERO payloads on the ordinary
  # publish — ordinary because autosave mints a draft before the author ever reaches the button — and
  # the released rows then read on the page's own timeline still offering a Restore, under a summary
  # row saying they are no longer restorable.
  #
  # THE LIVE BRANCH GOES WITH IT, deliberately and not as a side effect: those rows are exactly what
  # the published document's timeline draws — the published stage writes there too, and an error
  # page's four statuses share one — and the summary row lands above them saying so. What is left
  # alone is another author's OPEN draft, which is its own branch and has not shipped anything, and
  # that is the whole reason this is not simply "every row on the anchor".
  defp anchored_rows(source_type, source_id, draft_id, actor) do
    case rows_query(actor) do
      {:ok, query} ->
        query
        |> Ash.Query.filter(source_type == ^source_type and source_id == ^source_id)
        |> then(fn query ->
          case draft_id do
            nil -> Ash.Query.filter(query, is_nil(draft_id))
            id -> Ash.Query.filter(query, is_nil(draft_id) or draft_id == ^id)
          end
        end)
        |> Ash.Query.load([:snapshot])
        |> Ash.read(actor: actor)

      :error ->
        {:ok, []}
    end
  end

  # Deleting the snapshot nilifies `snapshot_id` on its row, which is what leaves a readable entry
  # that simply cannot be reverted into — the timeline says so rather than offering a broken button.
  #
  # AS THE SYSTEM, because a snapshot has no site to hold a user to: only a master deletes one
  # directly. The rows were read as the actor, so these are only payloads the actor may reach —
  # and a payload a row outside them still points at stays, since taking it would end that row's
  # Restore on a document this publish did not ship, on another site or another open draft.
  defp drop_snapshots(rows) do
    held =
      rows
      |> Enum.flat_map(fn
        %{snapshot: %{id: _} = snapshot} -> [snapshot]
        _no_payload -> []
      end)
      |> Enum.uniq_by(& &1.id)

    case held_elsewhere(held, rows) do
      {:ok, elsewhere} ->
        held
        |> Enum.reject(&MapSet.member?(elsewhere, &1.id))
        |> Enum.count(
          &match?({:ok, _}, Ash.destroy(&1, authorize?: false, return_destroyed?: true))
        )

      :error ->
        0
    end
  end

  defp held_elsewhere([], _rows), do: {:ok, MapSet.new()}

  defp held_elsewhere(snapshots, rows) do
    snapshot_ids = Enum.map(snapshots, & &1.id)
    row_ids = Enum.map(rows, & &1.id)

    PageBuilderEvent
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(snapshot_id in ^snapshot_ids and id not in ^row_ids)
    |> Ash.Query.select([:snapshot_id])
    |> Ash.read(authorize?: false, page: false)
    |> case do
      {:ok, others} -> {:ok, MapSet.new(others, & &1.snapshot_id)}
      _error -> :error
    end
  end

  defp write_summary(source_type, source_id, summary, actor) do
    PageBuilderEvent
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          source_type: source_type,
          source_id: source_id,
          kind: :publish,
          op: :publish,
          author_type: :system,
          inserted_at: DateTime.utc_now()
        },
        summary
      ),
      tenant: summary[:site_id],
      actor: actor
    )
    |> Ash.create()
  end

  @doc """
  Delete snapshots no row points at.

  They accumulate from two directions: a publish that dropped a row's payload, and the rarer race
  where two flushes of one entry both mint a snapshot before either row lands. Neither is worth
  preventing with a lock — a payload nothing references is garbage whatever produced it, and one
  statement removes all of it.

  Runs as the system, with no user: whether a payload is referenced is a question about every
  site's rows, and a user reaches only their own site's.
  """
  @spec sweep_orphan_snapshots() :: {:ok, non_neg_integer()}
  def sweep_orphan_snapshots do
    referenced =
      PageBuilderEvent
      |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
      |> Ash.Query.filter(not is_nil(snapshot_id))
      |> Ash.Query.select([:snapshot_id])
      |> Ash.read!(authorize?: false)
      |> MapSet.new(& &1.snapshot_id)

    PageBuilderSnapshot
    |> Ash.Query.for_read(:read, %{}, authorize?: false)
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&MapSet.member?(referenced, &1.id))
    |> Enum.count(&match?({:ok, _}, Ash.destroy(&1, authorize?: false, return_destroyed?: true)))
    |> then(&{:ok, &1})
  end

  @doc """
  Clear one document's whole recorded history.

  A whole anchor at a time, never a single row: removing one entry and leaving its neighbours is the
  operation that lets somebody quietly delete the evidence of one change, which is the thing a record
  of what happened exists to prevent.
  """
  @spec clear(atom(), String.t(), map() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def clear(source_type, source_id, actor) do
    with {:ok, query} <- rows_query(actor),
         {:ok, rows} <-
           query
           |> Ash.Query.filter(source_type == ^source_type and source_id == ^source_id)
           |> Ash.read(actor: actor) do
      Enum.each(rows, &Ash.destroy(&1, actor: actor, action: :destroy))
      {:ok, length(rows)}
    else
      :error -> {:ok, 0}
      error -> error
    end
  end

  defp truncate(nil, _max), do: nil
  defp truncate("", _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    case String.length(text) do
      n when n <= max -> text
      _longer -> String.slice(text, 0, max - 1) <> "…"
    end
  end

  defp truncate(other, max), do: other |> to_string() |> truncate(max)
end
