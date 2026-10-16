# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.PageBuilder.EditorSession.Journal do
  @moduledoc """
  What happened to the document, in the words a person would use, and the stack that lets them go
  back.

  Three modules share the editing record and each owns one part of it. `EditorHistoryState` keeps the
  DOCUMENTS — the way back — off the session row, because ETS flattens what it stores and entries
  that share nearly every node in memory would become independent copies. `History` writes the
  durable rows anyone can read later. This one owns the ENTRY: what it says, when two of them are
  really one gesture, and where it sits on the undo stack.

  ## An entry carries a reference, never a document

  Every entry holds a `ref` into `EditorHistoryState` and its own id, minted here rather than by the
  database — the flush is batched and retried, so a row has to be identifiable before it exists or a
  timeout that actually succeeded grows a duplicate on the retry.

  The `ref` is handed in rather than made here. A change to a session can be worked out more than
  once when another write lands first, and every function below writes its step under the reference
  its caller reserved before the first try — so a second try replaces the row the first one wrote
  instead of leaving it behind.

  ## One gesture is one change

  Two adjacent entries merge when they are the same kind of edit, to the same node, to the same FIELD
  of it, close together in time. Dragging a padding slider from 20px to 14px is one entry rather than
  seven, while padding and colour stay two. Coalescing keeps what the OLDER entry remembered and its
  id — the state before the whole gesture, rebuilt under the new change's reference, and the id
  because a row already written for the first keystroke should be updated by the finished sentence
  rather than joined by a second row saying almost the same thing.

  Stepping back and forward is folded the same way: five taps are one row saying net movement, not
  five saying one each, and a run that lands where it started is dropped before it is ever written.

  ## Trimming is by memory, not by count

  A count is wrong in both directions at once — fifty steps is a few minutes on a small page and
  57 MB of ETS on a large one — and being capped is what made the editor stop recording anything at
  all once it filled. The far end goes one step at a time until the session is inside its budget, and
  a single step bigger than the whole budget is kept anyway: a history that cannot go back at all is
  worse than being briefly over.

  Every path that drops an entry drops what it remembered with it. A trimmed entry, a discarded redo
  stack, a coalesced duplicate — each is a row in `EditorHistoryState` that nothing can reach
  afterwards, charged to the session's budget for the rest of its life. Nothing here deletes one,
  though: the session that still points at it is the stored one until this change is stored, so
  `MishkaCmsCore.Runtime.PageBuilder.EditorSession` deletes whatever left both stacks once it is.

  See `MishkaCmsCore.Runtime.PageBuilder.EditorSession`, which owns the session these operate on and
  is the only caller.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.PageBuilder.Op
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Patch
  alias MishkaCmsCore.Runtime.States.EditorHistoryState

  @coalesce_ms Application.compile_env(:mishka_cms_core, :builder_coalesce_ms, 600)

  @doc """
  Records one op, returning the session with the entry on its stack.

  A tree identical to the one already held is not an edit and passes straight through — tabbing
  through the style panel blurs every field on the way, each blur arriving as a `set_style` with the
  value it already had, and recording those made the author press undo once per field they walked
  over to take back one real change.
  """
  @spec record(map(), map(), Tree.t(), reference()) :: map()
  def record(%{tree: tree} = session, _op, tree, _ref), do: session

  # THE ENTRY CARRIES A REFERENCE, NOT A DOCUMENT. What it describes stays here — the label, what it
  # touched, when — and the way back goes to `EditorHistoryState`, because this struct is an ETS row
  # and ETS flattens what it stores: entries that share nearly every node in memory become
  # independent copies on the table, re-copied on every read of the session.
  def record(session, op, tree, ref) do
    entry = %{
      # MINTED HERE, not by the database. The flush is batched and retried, so the row it writes has
      # to be identifiable before it exists — otherwise a timeout that succeeded server-side grows a
      # duplicate on the retry.
      id: Ecto.UUID.generate(),
      label: Op.label(op),
      kind: op.kind,
      node_id: op.node_id,
      # WHICH field of that node, so two edits to the same node's padding merge while padding and
      # colour stay two changes. `nil` for ops that touch no single field.
      field: op_field(op),
      # What the op touched, in words. Without these the rail could only show the op's own name and
      # the node's random id — "set_attr · nyauaklow" — which says nothing to the person who made the
      # change and cannot be compared with the entry above it.
      target: target_label(tree, session.tree, op.node_id),
      detail: describe(op),
      note: note(op, session.tree),
      ref: ref,
      at: DateTime.utc_now(),
      monotonic: System.monotonic_time(:millisecond)
    }

    past = push_history(session, entry, tree)

    %{
      session
      | tree: tree,
        revision: session.revision + 1,
        past: past,
        step_run: nil,
        future: [],
        last_entry: entry,
        pending: queue(session.pending, hd(past)),
        dirty?: true
    }
  end

  # The entry as it stands after coalescing — which is the one worth writing, since it carries the
  # finished value and the id its earlier self already had.
  @doc "The entry as it stands after coalescing, waiting to be written."
  @spec queue(map() | nil, map()) :: map()
  def queue(pending, entry), do: Map.put(pending || %{}, entry.id, entry)

  # UNDO IS NET MOVEMENT, ONE ROW. Stepping back five times is one thing a person did, not five —
  # and undo/redo cancelling out is nothing at all. So consecutive steps REPLACE the pending row
  # rather than adding to it: the row carries where you ended up and how far you travelled, and if
  # you land where you started it is dropped before it is ever written.
  #
  # The in-memory stack is untouched by this: `undo/1` still just moves an entry between `past` and
  # `future`, which is what makes Ctrl+Z instant.
  @doc """
  The row a run of undos or redos writes — one row for the whole run, saying net movement.

  Five taps are one thing a person did, not five, and stepping back and forward again is nothing at
  all. The in-memory stack is untouched by this: `undo/1` still only moves an entry between `past`
  and `future`, which is what makes Ctrl+Z instant.
  """
  @spec step_entry(map(), :undo | :redo, reference()) :: map()
  def step_entry(session, direction, ref) do
    {steps, base} = step_run(session, direction)

    %{
      id: base.id,
      label: step_label(steps),
      kind: :undo,
      node_id: "history",
      field: :step,
      target: nil,
      detail: step_detail(steps),
      note: nil,
      # ONE DOCUMENT PER RUN, KEPT ONCE. This minted a fresh one on every tap, and the tap before it
      # became unreachable the moment its entry was replaced in the queue — a step entry never enters
      # `past` or `future`, so nothing could ever drop it. Measured: 160 taps on an 801-node page left
      # 32 MB of documents nothing could reach, four times the whole budget, and the trim then cut the
      # real history down to a single step for the rest of the session.
      #
      # The run's own document is also the RIGHT one: "net movement: 3 back" restores where the run
      # began, not where its last tap happened to land.
      ref: base[:ref] || EditorHistoryState.keep(session.token, ref, session.tree),
      at: base.at,
      monotonic: System.monotonic_time(:millisecond),
      steps: steps
    }
  end

  # The run this step belongs to: a pending step row keeps its id and its start time, so five taps
  # update one row instead of writing five.
  defp step_run(session, direction) do
    delta = if direction == :undo, do: -1, else: 1

    case session.step_run do
      nil -> {delta, %{id: Ecto.UUID.generate(), at: DateTime.utc_now()}}
      previous -> {(previous[:steps] || 0) + delta, previous}
    end
  end

  defp step_label(0), do: gettext("Stepped back and forward again")

  defp step_label(n) when n < 0,
    do: ngettext("Stepped back %{count} change", "Stepped back %{count} changes", abs(n))

  defp step_label(n),
    do: ngettext("Stepped forward %{count} change", "Stepped forward %{count} changes", n)

  defp step_detail(0), do: gettext("net movement: none")
  defp step_detail(n) when n < 0, do: gettext("net movement: %{count} back", count: abs(n))
  defp step_detail(n), do: gettext("net movement: %{count} forward", count: n)

  # A RUN THAT PRODUCED THE VERY SAME TREE IS NOT AN EDIT — the same rule `record/4` has kept for
  # single ops, and it matters more here. The drawer's Apply is a delete-and-insert of whatever text
  # the box submitted; if that text is what the node already said, this recorded a history entry,
  # marked the document dirty and broadcast a change that nobody could see. An apply that did
  # nothing then looked exactly like one that worked.
  @doc """
  Records many ops as ONE entry — a bulk action, a find-and-replace, an assistant's answer.

  `opts` names who made it (`:author_type`, `:prompt`, `:backend`), which is where an assistant's row
  gets its own sentence and the model behind it. Defaulting to `:human` leaves every other caller what
  it was. A run producing the very same tree is not an edit, for the reason `record/4` gives.
  """
  @spec record_run(map(), Tree.t(), String.t(), reference(), keyword()) :: map()
  def record_run(%{tree: tree} = session, tree, _label, _ref, _opts), do: session

  # WHO MADE THIS RUN, and what they were asked. A run is the shape the assistant works in — one
  # prompt, one ops list, one entry — so this is where an assistant's row gets its own name, its own
  # sentence, and the model behind it, all of which the timeline already draws.
  #
  # Defaulting to `:human` keeps every existing caller — find-and-replace, bulk delete, duplicate,
  # paste styles — exactly what it was.
  def record_run(session, tree, label, ref, opts) do
    entry = %{
      id: Ecto.UUID.generate(),
      label: label,
      kind: :run,
      node_id: nil,
      field: nil,
      target: nil,
      detail: nil,
      note: Keyword.get(opts, :note),
      bucket: Keyword.get(opts, :bucket),
      author_type: Keyword.get(opts, :author_type, :human),
      prompt: Keyword.get(opts, :prompt),
      backend: Keyword.get(opts, :backend),
      ref: EditorHistoryState.put(session.token, ref, session.tree, tree),
      at: DateTime.utc_now(),
      monotonic: System.monotonic_time(:millisecond)
    }

    %{
      session
      | tree: tree,
        revision: session.revision + 1,
        past: trim_history([entry | session.past], session.token),
        future: [],
        pending: queue(session.pending, entry),
        step_run: nil,
        last_entry: nil,
        dirty?: true
    }
  end

  # Consecutive text edits on one node inside the coalesce window replace the top entry instead of
  # stacking, so a typed sentence is one undo step. The tree kept is the one from BEFORE the first
  # keystroke — that is what undo restores — while everything the reader sees comes from the latest,
  # so the rail quotes the finished sentence rather than its first letter.
  #
  # Coalescing therefore replaces the older entry's step, and trimming drops the one that falls off
  # the end; either way the entry that leaves the stack takes its row with it, or the table grows
  # for the life of the session.
  defp push_history(session, entry, tree) do
    case coalesce?(session.last_entry, entry) do
      true ->
        top = hd(session.past)

        # KEEPS THE OLDER ENTRY'S ID as well as what it remembers. What it remembers is the state
        # before the whole gesture — and the id is what the durable row is keyed by, so a row already
        # written for the first keystroke is UPDATED by the finished sentence rather than joined by a
        # second row saying almost the same thing.
        [%{entry | ref: recoalesce(session, top, entry.ref, tree), id: top.id} | tl(session.past)]

      false ->
        EditorHistoryState.put(session.token, entry.ref, session.tree, tree)
        trim_history([entry | session.past], session.token)
    end
  end

  # AND ITS PATCH IS REBUILT. A patch reverses one step from wherever the document has got to, and
  # the gesture has moved it since this entry was recorded — so the way back has to be described
  # from the new state, not from the intermediate one it was written against.
  #
  # UNDER THIS CHANGE'S REFERENCE, NOT OVER THE OLD ONE. Until this change is stored, the session
  # everyone reads still points at the old step and expects it to be the way back from the old
  # document; rewriting it in place handed a concurrent undo the wrong patch, and a change that lost
  # its race left the old entry describing a document that was never stored.
  defp recoalesce(session, top, ref, tree) do
    case EditorHistoryState.fetch(session.token, top.ref) do
      {:ok, {:patch, patch}} ->
        EditorHistoryState.put(session.token, ref, Patch.apply_to(session.tree, patch), tree)

      _standalone ->
        top.ref
    end
  end

  # THE STORED STEPS GO WITH THE ENTRIES. Trimming used to be `Enum.take/2` and nothing else; the
  # rows that fall off the end have to be dropped too, or a long sitting leaves a stored step behind
  # for every one it forgets. They are dropped once the trimmed session is stored, so the running
  # total is counted down here by what each one holds rather than asked again.
  #
  # BY MEMORY, NOT BY COUNT. A count is wrong in both directions at once: fifty steps was a few
  # minutes on a small page and 57 MB of ETS on a large one — and being capped is what made the
  # editor stop recording anything at all once it filled.
  #
  # The far end goes first, one step at a time, until the session is inside its budget again. A
  # single step that is somehow bigger than the whole budget is kept anyway; dropping it would leave
  # a history that cannot go back at all, which is worse than being briefly over.
  @doc """
  Drops entries from the far end until the session is inside its memory budget.

  What the dropped entries remembered is not deleted here — the session still pointing at them stays
  the stored one until the trimmed one replaces it.
  """
  @spec trim_history([map()], String.t()) :: [map()]
  def trim_history(entries, token), do: trim(entries, token, EditorHistoryState.bytes(token))

  defp trim(entries, token, bytes) do
    case bytes > EditorHistoryState.max_bytes() do
      true -> drop_oldest(entries, token, bytes)
      false -> entries
    end
  end

  defp drop_oldest([_only] = entries, _token, _bytes), do: entries

  defp drop_oldest(entries, token, bytes) do
    {kept, [oldest]} = Enum.split(entries, length(entries) - 1)
    trim(kept, token, bytes - EditorHistoryState.bytes(token, oldest.ref))
  end

  # ONE GESTURE IS ONE CHANGE. Two adjacent entries merge when they are the same kind of edit, to the
  # same node, to the same FIELD of it, close together in time — so dragging a padding slider from
  # 20px to 14px is one entry rather than seven, while padding and colour stay two.
  #
  # This used to fire for `:set_text` alone, which left every slider drag and every colour scrub
  # writing an entry per intermediate value: one Ctrl+Z per tick, and a timeline nobody could read.
  # Fixed HERE and nowhere else, so the undo stack, the rail and the durable rows cannot disagree.
  #
  # A `:run` never merges — `record_run/3` clears `last_entry` for exactly that reason — and neither
  # does anything with no field to compare, which is every structural op: two deletes in a row are
  # two deletions, not one.
  defp coalesce?(nil, _entry), do: false

  defp coalesce?(%{kind: kind, node_id: id, field: field, monotonic: was}, %{
         kind: kind,
         node_id: id,
         field: field,
         monotonic: now
       })
       when not is_nil(id) and (not is_nil(field) or kind == :set_text),
       do: now - was <= @coalesce_ms

  defp coalesce?(_previous, _entry), do: false

  # WHICH field of the node an op touches, for the rule above. A style override is identified by its
  # property AND the bucket it sits in, or hovering and resting states of one property would merge.
  defp op_field(%{kind: :set_style, prop: prop, bucket: bucket}) when is_binary(prop),
    do: {prop, bucket}

  defp op_field(%{kind: :set_attr, name: name}) when is_binary(name), do: name
  defp op_field(%{kind: :set_text}), do: :text
  defp op_field(_op), do: nil

  # The name a reader would use for the node, not its id: a component's own name, a slot's, or the
  # tag. Looked up in the tree the op produced and then in the one it replaced, because an insert
  # only exists in the first and a delete only in the second.
  defp target_label(after_tree, before_tree, node_id) when is_binary(node_id) do
    named(Tree.get(after_tree, node_id)) || named(Tree.get(before_tree, node_id))
  end

  defp target_label(_after_tree, _before_tree, _node_id), do: nil

  defp named(nil), do: nil

  # A text node, a comment and an EEx expression have no tag to print — the layers tree names them by
  # kind, and so does this. Printing `node.tag` for them produced the empty `<>`.
  defp named(%Node{kind: :tag, tag: tag}) when is_binary(tag) and tag != "", do: "<#{tag}>"

  defp named(%Node{kind: kind} = node) when kind in [:component, :slot] do
    case Node.component_name(node) || Node.slot_name(node) do
      nil -> nil
      name -> "<.#{name}>"
    end
  end

  defp named(%Node{kind: :text}), do: gettext("text")
  defp named(%Node{kind: :eex}), do: gettext("expression")
  defp named(%Node{kind: :eex_block}), do: gettext("block")
  defp named(%Node{kind: kind}) when kind in [:eex_comment, :html_comment], do: gettext("comment")
  defp named(_node), do: nil

  # The change itself, in the words of the thing that changed rather than the op that changed it.
  # "class = px-6" is something the person who typed it recognises; "set_attr · nyauaklow" is not.
  defp describe(%{kind: :set_attr, name: name, value_kind: :boolean}),
    do: gettext("%{name} enabled", name: name)

  defp describe(%{kind: :set_attr, name: name, value: value}), do: "#{name} = #{shorten(value)}"
  defp describe(%{kind: :delete_attr, name: name}), do: gettext("%{name} removed", name: name)
  defp describe(%{kind: :set_text, text: text}), do: "“#{shorten(text)}”"

  defp describe(%{kind: :set_style, prop: prop, value: value, bucket: bucket}),
    do: "#{prop}: #{shorten(value)} · #{bucket}"

  defp describe(%{kind: :reset_styles, bucket: bucket}),
    do: gettext("all %{bucket} overrides cleared", bucket: bucket)

  defp describe(%{kind: :wrap, tag: tag}), do: gettext("new <%{tag}> around it", tag: tag)

  defp describe(%{kind: :insert, template: template}) when is_binary(template),
    do: shorten(template)

  defp describe(_op), do: nil

  defp shorten(nil), do: ""

  defp shorten(value) when is_binary(value) do
    trimmed = value |> String.replace(~r/\s+/, " ") |> String.trim()

    case String.length(trimmed) do
      length when length > 48 -> String.slice(trimmed, 0, 47) <> "…"
      _short -> trimmed
    end
  end

  defp shorten(value), do: to_string(value)

  # A plain-language consequence, for the two ops that take more with them than their own line says.
  # Everything else is already fully described by its label and detail, and a note under every entry
  # would be noise the reader learns to skip.
  defp note(%{kind: :delete, node_id: node_id}, before_tree) do
    case length(Tree.descendant_ids(before_tree, node_id)) do
      0 ->
        nil

      count ->
        ngettext(
          "%{count} nested element went with it. Undo brings them back.",
          "%{count} nested elements went with it. Undo brings them back.",
          count
        )
    end
  end

  defp note(%{kind: :reset_styles, bucket: bucket}, _before_tree),
    do:
      gettext(
        "Every %{bucket} override on this element is gone — it falls back to the base styles.",
        bucket: bucket
      )

  defp note(_op, _before_tree), do: nil

  # THE STEPS BETWEEN HERE AND THERE. A patch reverses exactly one step from the version after it, so
  # a version several steps away is reached by applying each patch in between — which is why this
  # lives here rather than in the store: the session is the thing that knows the order.
  @doc """
  The entries between where the document is now and the version `ref` names, or `nil` when it is on
  neither stack.

  A patch reverses exactly one step, so a version several steps away is reached by applying each
  patch in between — which is why this lives here rather than in the store: the session is the thing
  that knows the order.
  """
  @spec steps_to(map(), String.t()) :: [map()] | nil
  def steps_to(session, ref) do
    Enum.find_value([session.past, session.future], fn entries ->
      case Enum.find_index(entries, &(&1.ref == ref)) do
        nil -> nil
        index -> Enum.take(entries, index + 1)
      end
    end)
  end

  @doc "The selection if it still exists in `tree`, otherwise `nil`."
  @spec valid_selection(Tree.t(), String.t() | nil) :: String.t() | nil
  def valid_selection(tree, selection) do
    case Tree.get(tree, selection) do
      nil -> nil
      _node -> selection
    end
  end

  @doc "The entry for a wholesale replacement of the document — a save, a draft, a revert."
  @spec replacement_entry(map(), Tree.t(), atom(), reference()) :: map()
  def replacement_entry(session, tree, reason, ref) do
    {label, kind, detail} = replacement_words(reason)

    %{
      id: Ecto.UUID.generate(),
      label: label,
      kind: kind,
      node_id: nil,
      field: nil,
      target: nil,
      detail: detail,
      note: nil,
      ref: EditorHistoryState.put(session.token, ref, session.tree, tree),
      at: DateTime.utc_now(),
      monotonic: System.monotonic_time(:millisecond)
    }
  end

  # Each replacement says what it actually was. They all used to read "Restored", so a hand-edited
  # source and a starter layout both appeared in the record as something the author never did.
  defp replacement_words(:revert),
    do: {gettext("Restored"), :restore, gettext("the whole document, from an earlier point")}

  defp replacement_words(:source_edit),
    do:
      {gettext("Edited the source"), :source_edit,
       gettext("the whole document, rewritten by hand")}

  defp replacement_words(:page_starter),
    do: {gettext("Started from a layout"), :replace, gettext("the whole document, replaced")}

  defp replacement_words(:element_css),
    do: {gettext("Edited element CSS"), :set_style, gettext("the whole document, rewritten")}

  defp replacement_words(:interaction),
    do: {gettext("Changed an interaction"), :set_attr, gettext("the whole document, rewritten")}

  defp replacement_words(:js_hook),
    do: {gettext("Changed a script hook"), :set_attr, gettext("the whole document, rewritten")}

  defp replacement_words(_other),
    do: {gettext("Restored"), :restore, gettext("the whole document, from an earlier point")}
end
