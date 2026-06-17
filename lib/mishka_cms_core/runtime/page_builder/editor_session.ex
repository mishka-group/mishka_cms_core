defmodule MishkaCmsCore.Runtime.PageBuilder.EditorSession do
  @moduledoc """
  One open editing session: the working tree plus everything around it — selection, hover, undo
  history, clipboard, per-node locks, the breakpoint and state being edited.

  ## Why the server holds this

  The editor is two LiveViews — the chrome and the canvas inside its iframe — and they must agree on
  one document. They share a token, not a copy: every mutation goes through `apply_op/3` here, lands
  in ETS, and is announced on the session's PubSub topic, so each LiveView re-renders what it owns.
  That single funnel is also where containment is re-checked, where the undo history is pushed, and
  where the `builder:node:*` plugin seams fire.

  It is also what makes undo, clipboard and shortcuts *real*. The React editor shipped a complete
  history implementation watching a store nothing ever wrote to, so every one of its thirteen
  advertised shortcuts was inert. Here the history is the same data structure the canvas renders
  from, so a working undo is not a feature to add later — it falls out.

  ## What lives here, and what does not

  This module is the funnel and the state: it reads the session, applies a change, checks containment,
  writes it back and announces it. Two things it used to also be were lifted out, because each is a
  whole question of its own and neither needs the token or the table to answer it:

    * `MishkaCmsCore.Runtime.PageBuilder.Placement` — WHERE a thing lands. A click, a drag and a
      template arriving on its own all ask it the same question, and it answers from the tree alone.
      It sits beside `Containment`, which answers whether a child may go in a parent at all;
    * `MishkaCmsCore.Runtime.PageBuilder.EditorSession.Journal` — WHAT HAPPENED, in the words a
      person would use, and the undo stack it sits on. It owns coalescing, trimming and the step
      rows; the documents themselves stay in `EditorHistoryState` and the durable rows in `History`.

  Both take and return plain data, so they can be read and tested without opening a session — which
  is what they were missing.

  Two more answer for the page's forms, and both are consulted from the funnel rather than owned by
  it: `MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement` puts a form around a field that
  lands without one, and `MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming` renumbers a form name
  that a copy, a paste or a pasted document has just made ambiguous.

  ## History semantics (from the v2 prototype)

  As deep as its memory budget allows rather than a fixed number of steps — see
  `MishkaCmsCore.Runtime.States.EditorHistoryState`, which holds each step as what changed rather
  than as a whole document, and drops the oldest when a session has kept too much. A new edit
  truncates the redo stack. Consecutive text edits on the same node inside
  `#{Application.compile_env(:mishka_cms_core, :builder_coalesce_ms, 600)} ms` coalesce into one
  entry, so typing a headline is one undo, not forty.

  ## Concurrency

  Two admins on the same page see each other through `Phoenix.Presence` on this topic, and edits are
  last-write-wins at the op level. Per-node locking is the escape hatch. A real CRDT is explicitly
  out of scope; op-level granularity keeps the damage from a genuine collision to a single element.

  One session is written by more than one process as well — the chrome, the canvas, and the tasks
  each of them starts to flush the history, autosave and load the palette. None of those writes may
  put back what another one changed, so every change here is worked out on the session as stored and
  landed with a compare-and-swap; see `MishkaCmsCore.Runtime.States.EditorSessionState.update/2`.

  ## One change, or many

  `apply_op/3` is one change: one read of the session, one write, one broadcast, one undo step. That
  is the right shape for a person, and the wrong shape for anything that produces a document —
  an assistant writing a section, an import, a paste of forty elements. Each op there costs a full
  copy of the session out of ETS and back, a history snapshot, and a re-render in every LiveView
  watching, so forty ops is forty of everything and the editor spends the whole time drawing
  intermediate states nobody asked to see.

  **Anything writing more than one thing should call `apply_ops/4`.** It folds the run over one tree
  in memory, stores it once, broadcasts once, and keeps one undo entry — which is also what a reader
  means by "undo what it just did". Measured on a 302-node page inserting forty elements: 15.7 ms
  and forty history entries, against 3.6 ms and one.
  """
  use GuardedStruct
  use Gettext, backend: MishkaCmsCore.Gettext

  require MishkaCmsCore.Runtime.PageBuilder.Strict

  alias MishkaCmsCore.Builder.Events
  alias MishkaCmsCore.Runtime.PageBuilder.Containment
  alias MishkaCmsCore.Runtime.PageBuilder.ElementScopes
  alias MishkaCmsCore.Runtime.PageBuilder.Elements
  alias MishkaCmsCore.Runtime.PageBuilder.Fields
  alias MishkaCmsCore.Runtime.PageBuilder.Inspector
  alias MishkaCmsCore.Runtime.PageBuilder.Op
  alias MishkaCmsCore.Runtime.PageBuilder.Sequence
  alias MishkaCmsCore.Runtime.PageBuilder.Starter
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.FormPlacement
  alias MishkaCmsCore.Runtime.PageBuilder.Ids
  alias MishkaCmsCore.Runtime.PageBuilder.PageForms.Naming
  alias MishkaCmsCore.Runtime.PageBuilder.Presets
  alias MishkaCmsCore.Runtime.PageBuilder.Strict
  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.EditorSession.Journal
  alias MishkaCmsCore.Runtime.PageBuilder.Placement
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Node
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Patch
  alias MishkaCmsCore.Runtime.PageBuilder.Visibility
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Serializer
  alias MishkaCmsCore.Runtime.States.EditorHistoryState
  alias MishkaCmsCore.Runtime.States.EditorSessionState

  @pubsub MishkaCmsCore.PubSub

  @sections ~w(page layout error_page component)

  @naming_kinds [:insert, :duplicate, :wrap, :wrap_many]
  @breakpoints [:base, :tablet, :mobile]
  @pseudos [:base, :hover, :focus, :active]

  guardedstruct do
    field(:token, :string, enforce: true, derives: "validate(string, regex=^[a-z0-9]{32}$)")

    field(:section, :string,
      enforce: true,
      derives: "validate(enum=String[page::layout::error_page::component])"
    )

    field(:resource_id, :string)
    # WHICH OF THE DOCUMENT'S TEMPLATES THIS TREE CAME FROM. `nil` for every section but an error
    # page, which stores a LIST of `%{status, template, layout}` — so "the document" there is the
    # record AND a status, and a session that knows only the record is a session for five different
    # templates at once — a code, or `:offline` for the page an offline site shows. See
    # `MishkaCmsCore.Runtime.States.EditorSessionState.find/4`.
    field(:status, MishkaCmsCore.Runtime.ErrorStatus.t())
    field(:site_id, :string)
    field(:site_name, :string)
    field(:actor_id, :string)
    field(:tree, any())
    field(:selection, :string)
    field(:hover, :string)
    field(:breakpoint, :atom, default: :base)
    field(:pseudo, :atom, default: :base)
    field(:dir, :string, default: "ltr")
    # The CSS an author wrote for individual elements, already compiled. It rides the session for
    # the same reason `dir` does: that is what gets it into the canvas frame without reloading it,
    # and the frame must show the change now rather than one recompile later.
    field(:element_css, :string, default: "")

    # THE ELEMENT CSS THIS SITTING HAS TYPED AND NOT PUBLISHED, as `%{scope => body}` with a blank
    # body for a box the author emptied, or nil when nothing is held. The row it ends up in IS the
    # live site — writing one recompiles the site bundle — so CSS applied while the stage says Draft
    # waits here, next to the markup carrying the scope classes it is keyed on, and the publish that
    # writes that markup folds these into the row with it.
    #
    # EDITS, NOT THE DOCUMENT'S CSS. The row is shared — an error page's five statuses write into
    # one, and so does a second browser on this same session — so what a publish needs from here is
    # which elements were touched, never a whole map to write over everything else.
    field(:staged_element_css, any())
    field(:preview?, :boolean, default: false)
    field(:picked, :string)
    field(:clipboard, any())
    field(:clipboard_label, :string)

    # A SECOND CLIPBOARD, for looks rather than content — see `copy_styles/2`. Holding both in one
    # slot would mean copying a card to match its styling silently discarded whatever was waiting to
    # be pasted.
    field(:styles, any())
    field(:styles_label, :string)
    # THE OTHER SELECTED NODES. `selection` stays exactly one element — it is what the inspector
    # edits, what the toolbar names and what the breadcrumb walks — and these are the ones held with
    # it. Everything that reads a single selection therefore keeps working untouched, and the handful
    # of actions that mean "all of them" ask for `chosen/1`.
    field(:marked, any())
    field(:past, list(), default: [])
    field(:future, list(), default: [])
    field(:dirty?, :boolean, default: false)
    # HOW MANY TIMES THE DOCUMENT HAS MOVED, counted rather than measured. The chrome used to ask
    # `{length(past), length(future)}` whether anything had changed, and the undo stack was capped —
    # so once it filled, the answer was "no" forever, and the editor quietly stopped autosaving and
    # stopped recording history. A counter cannot saturate.
    field(:revision, :integer, default: 0)

    # THE RUN OF UNDOS CURRENTLY UNDER WAY. Five taps are one row saying net movement, not five rows
    # saying one each — and the pending buffer cannot carry that, because every change flushes it, so
    # by the second tap the first had already been written and drained. It lives here instead, and is
    # cleared by the next real edit, which is what actually ends a run.
    field(:step_run, any())
    # WHERE THE NEXT PRESS GOES, kept here and not only in the chrome so a reload can tell the two
    # apart: draft work is resumed, publish work is not — nothing was written for it, and the bar
    # promises a reload shows the original.
    field(:stage, :atom, default: :draft)
    field(:saved_at, any())
    field(:draft_id, :string)
    # The NAME of the draft being edited, or nil for the live document. The editor's top bar reads
    # this: an editor that silently writes somewhere you did not choose is the thing to avoid, so
    # every save target is named on screen.
    field(:draft_label, :string)
    field(:locked, any())
    field(:hidden, any())

    # The overlays held open on the canvas. A dialog opens when it is selected and shuts again when
    # the selection moves on, which is what an author wants nine times in ten; this is the tenth,
    # where the point is the page BEHIND it.
    field(:pinned, any())
    field(:components, list(), default: [])
    field(:last_entry, any())
    # SETTLED ROWS WAITING FOR THE DATABASE. Keyed by the entry's own id, so a coalesced entry
    # replaces its earlier self rather than queueing twice, and a flush that already wrote one
    # upserts onto the same row. Lives here because the session survives a dropped socket and the
    # flushing task does not.
    field(:pending, any(), default: %{})

    # WHEN THIS SITTING BEGAN. The draft is created lazily — the first few changes of a session are
    # recorded before one exists — so this bounds which rows belong to it when it appears. See
    # `MishkaCmsCore.Runtime.PageBuilder.History.adopt_draft/3`.
    field(:opened_at, any())
    # The wizard's current choices, `%{"variant" => "outline"}`. Held here rather than in the
    # chrome's assigns because the wizard's preview is a SECOND LiveView in an iframe, and the
    # session is the only thing the two share.
    field(:wizard, any(), default: %{})
  end

  @doc "The breakpoints an override may be recorded against."
  @spec breakpoints() :: [atom()]
  def breakpoints, do: @breakpoints

  @doc "The element states an override may be recorded against."
  @spec pseudos() :: [atom()]
  def pseudos, do: @pseudos

  @doc "The resource sections the builder can edit."
  @spec sections() :: [String.t()]
  def sections, do: @sections

  @doc "A fresh session token — 32 lowercase base32 characters, also the canvas iframe's URL segment."
  @spec generate_token() :: String.t()
  def generate_token,
    do: :crypto.strong_rand_bytes(20) |> Base.encode32(case: :lower, padding: false)

  @doc "The PubSub topic both LiveViews of a session subscribe to."
  @spec topic(String.t()) :: String.t()
  def topic(token), do: "builder:session:#{token}"

  @doc "Subscribes the calling process to a session's updates."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(token), do: Phoenix.PubSub.subscribe(@pubsub, topic(token))

  @doc """
  Opens a session over a template and stores it.

  `:template` is the HEEx to edit; a malformed one returns `{:error, %{line:, column:, message:}}`
  so the editor can show it rather than failing the mount.
  """
  @spec open(map()) :: {:ok, t()} | {:error, term()}
  def open(attrs) do
    with {:ok, session} <- build(attrs) do
      {:ok, EditorSessionState.put(session.token, session)}
    end
  end

  @doc """
  The same session WITHOUT registering it.

  A LiveView mounts twice — once for the static render, once when the socket connects — and
  registering on both left an orphaned session in ETS on every page load, with a different token, so
  the canvas iframe pointed at one URL and then at another and loaded twice. The static render uses
  this; only the connected mount calls `open/1`.
  """
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(attrs) do
    with {:ok, tree} <- Tree.parse(attrs[:template]),
         {:ok, base} <- builder(scalars(attrs)) do
      components = attrs[:components] || []

      {:ok,
       %{
         base
         | tree: tree |> Tree.unshare_scopes() |> backfill_ids(components),
           locked: MapSet.new(),
           hidden: MapSet.new(),
           pinned: MapSet.new(),
           marked: MapSet.new(),
           opened_at: DateTime.utc_now(),
           components: components
       }}
    end
  end

  # `Tree.unshare_scopes/1` runs here for the reason the ids below do, and for the documents that
  # already exist rather than the ones written from here on. Stopping Paste styles from carrying the
  # source's minted class does nothing for the markup it already carried it into: that target still
  # answers with the source's name, so its CSS box still shows the source's rule and the next save
  # still prunes its own away. A save only ever happens from an open session, so this is ahead of
  # every one of them.
  #
  # Every node that declares an `id` and has not been given one gets one when the page is OPENED,
  # not only when it is inserted. A page written before this existed — by hand, by a seed, by an
  # earlier version of the editor — arrives with the field blank and required, which is a page that
  # cannot be saved until someone invents a value nobody has an opinion about. Filling it on load
  # makes the common case correct, and it is an ordinary attribute afterwards: visible in the
  # inspector, renamable, and left alone once it has a value.
  #
  # It is deliberately NOT marked dirty. Opening a page is not an edit, and a builder that announces
  # unsaved changes for a page nobody touched teaches people to ignore the warning.
  defp backfill_ids(tree, components) do
    session = %{components: components}

    tree
    |> Tree.walk()
    |> Enum.reduce(tree, fn node, acc -> put_generated_id(acc, node, session) end)
  end

  defp scalars(attrs) do
    %{
      token: attrs[:token] || generate_token(),
      section: attrs[:section],
      resource_id: attrs[:resource_id],
      site_id: attrs[:site_id],
      site_name: attrs[:site_name],
      actor_id: attrs[:actor_id],
      draft_id: attrs[:draft_id],
      # WHICH TEMPLATE OF THE DOCUMENT THIS TREE IS. An error page holds one per status, so the
      # status is part of what the session is FOR — it keys the lookup that resumes one, and it is
      # what the autosave writes back into. Left out of this whitelist it was silently nil, which
      # made every status look like the same session and every draft land on the default entry.
      status: attrs[:status]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Fetches an open session."
  @spec fetch(String.t()) :: {:ok, t()} | :error
  def fetch(token), do: EditorSessionState.get(token)

  @doc "Closes a session and drops its state."
  @spec close(String.t()) :: :ok
  def close(token) do
    EditorHistoryState.delete_all(token)
    EditorSessionState.delete(token)
  end

  @doc """
  The one mutation funnel: validate the op, re-check containment, apply it, record history, store
  and announce.

  An op that leaves the tree exactly as it was is applied but never recorded — see
  `MishkaCmsCore.Runtime.PageBuilder.EditorSession.Journal.record/4`.

  `params` is raw client input. Returns `{:ok, session}` or `{:error, reason}`, where `reason` is
  either a validation error list or a user-facing containment message.

  `announce: how` announces `builder:form:after_create` with that `how` for each form the op made
  work.
  """
  @spec apply_op(String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def apply_op(token, params, opts \\ []) do
    step = make_ref()

    commit(
      token,
      fn session ->
        with {:ok, built} <- Op.build(params),
             {:ok, op} <- Events.before_node(built.kind, built, node_meta(session)),
             :ok <- authorize(session, op),
             :ok <- check_containment(session, op),
             {:ok, tree, focus} <- run(op, session.tree) do
          next =
            session
            |> Journal.record(op, settled(tree, op, focus, session, session.tree), step)
            |> prune_ids()
            |> focus_on(focus)

          {:store, next, {:op_applied, op.kind},
           &(&1 |> made_forms(session.tree, opts[:announce]) |> announce_node(op))}
        end
      end,
      [steps: [step]] ++ opts
    )
  end

  # AN ID SET OUTLIVES THE NODE IT NAMES. The selection, the marks, the locks and the hidden flags
  # are ids held BESIDE the tree, and an op that removes an element removes it from the tree and from
  # nothing else. So the bulk bar went on counting an element that was gone, and the action it
  # offered — copy it, delete it, wrap them — ran against an id resolving to nothing; a lock survived
  # the element it protected, and the layers rail hid a node that was not there.
  #
  # `put_tree/3` already re-homes all four across a whole-document replacement, where every id is
  # stale at once. This is the same care for the ordinary case, where exactly one subtree left.
  # Before `focus_on/2`, so an op that reports a node it just created still gets to select it.
  defp prune_ids(%{tree: tree} = session) do
    %{
      session
      | marked: still_present(session.marked, tree),
        locked: still_present(session.locked, tree),
        hidden: still_present(session.hidden, tree),
        pinned: still_present(session.pinned, tree),
        selection: present_id(session.selection, tree),
        hover: present_id(session.hover, tree)
    }
  end

  defp still_present(nil, _tree), do: MapSet.new()

  defp still_present(ids, tree),
    do: ids |> Enum.filter(&(not is_nil(Tree.get(tree, &1)))) |> MapSet.new()

  defp present_id(nil, _tree), do: nil
  defp present_id(id, tree), do: (Tree.get(tree, id) && id) || nil

  # THE SEAM THE MODULEDOC HAS ALWAYS PROMISED. `builder:node:before_*` is documented as the
  # transform every node mutation passes through — a plugin may rewrite the op or refuse it — and
  # nothing called it, so every content lint, schema check and link validator hung off a seam that
  # never fired. Measured at 0.77 µs with nothing registered, against ops costing hundreds.
  defp node_meta(session) do
    %{
      token: session.token,
      section: session.section,
      resource_id: session.resource_id,
      site_id: session.site_id,
      actor_id: session.actor_id
    }
  end

  defp announce_node(session, op) do
    Events.after_node(op.kind, %{
      token: session.token,
      section: session.section,
      resource_id: session.resource_id,
      site_id: session.site_id,
      actor_id: session.actor_id,
      kind: op.kind,
      node_id: Map.get(op, :node_id)
    })

    {:ok, session}
  end

  @doc """
  Applies a RUN of ops as one change: one read, one write, one broadcast, one undo step.

  `apply_op/3` is the right shape for a person, who makes one change at a time and wants each of them
  undoable on its own. It is the wrong shape for anything producing a document — an assistant writing
  a section, an import, a paste of forty elements — because every op there costs a full copy of the
  session out of ETS and back, a history snapshot, a broadcast, and a re-render in every LiveView
  watching. Forty of those is forty of everything, and the editor spends the whole time redrawing
  intermediate states nobody asked to see.

  Here the ops are folded over one tree in memory and stored once. The undo step is the whole run,
  which is also what a reader means by "undo what it just did".

  Stops at the first op that will not apply and returns its error, leaving the session untouched —
  a half-written section is worse than a refused one. `label` names the single history entry.

  `opts` may also say whose run this was, which is what the record needs to tell an assistant's work
  from a person's: `author_type: :ai`, plus the `note` it wrote about what it did, the `prompt` it
  was given and the `backend` that answered. An `:ai` run is also allowed a larger restore point —
  see `MishkaCmsCore.Runtime.PageBuilderSnapshot`. `announce: how` announces
  `builder:form:after_create` with that `how` for each form the run made work.
  """
  @spec apply_ops(String.t(), [map()], String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def apply_ops(token, params_list, label, opts \\ []) when is_list(params_list),
    do: run_ops(token, fn _session -> {:ok, params_list, label} end, opts)

  # A RUN WORKED OUT FROM THE DOCUMENT IS PLANNED INSIDE THE CHANGE. `plan` answers
  # `{:ok, params_list, label}` off the stored session and is asked again on the session another write
  # left, so no op carries a value worked out from a document that is no longer the stored one.
  defp run_ops(token, plan, opts) do
    step = make_ref()

    commit(
      token,
      fn session ->
        with {:ok, params_list, label} <- plan.(session),
             {:ok, tree, focus} <- fold_ops(session, params_list) do
          next =
            session
            |> Journal.record_run(tree, label, step, opts)
            |> prune_ids()
            |> focus_run(focus)

          {:store, next, {:op_applied, :run},
           &{:ok, made_forms(&1, session.tree, opts[:announce])}}
        end
      end,
      [steps: [step]] ++ opts
    )
  end

  # AGAINST THE TREE AS IT IS BECOMING, not as it was: an op that inserts into a node an earlier op
  # created has to see it. The session is threaded too, because containment and id generation both
  # read the palette off it.
  defp fold_ops(session, params_list) do
    Enum.reduce_while(params_list, {:ok, session.tree, nil}, fn params, {:ok, tree, _focus} ->
      staged = %{session | tree: tree}

      with {:ok, built} <- Op.build(params),
           {:ok, op} <- Events.before_node(built.kind, built, node_meta(staged)),
           :ok <- authorize(staged, op),
           :ok <- check_containment(staged, op),
           {:ok, next, focus} <- run(op, tree) do
        {:cont, {:ok, settled(next, op, focus, staged, session.tree), focus}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
        error -> {:halt, error}
      end
    end)
  end

  # The tree as it will be STORED: an id for what was just created, and one form name per form.
  # `start` is the tree the whole change began from, which a run's later ops still compare against.
  defp settled(tree, op, focus, session, start) do
    tree
    |> with_id(op, focus, session)
    |> deduped(op, session.tree, start)
    |> unfurnished(op, session)
    |> sequenced(op, focus, session)
    |> filed(op, focus, session)
  end

  # A form a file field is put or moved into sends files (`FormPlacement.filed/3`).
  defp filed(tree, %{kind: :move, node_id: id}, _focus, session) when is_binary(id),
    do: FormPlacement.filed(tree, id, session.components)

  defp filed(tree, %{kind: kind}, focus, session)
       when kind in [:insert, :duplicate, :paste, :wrap] and is_binary(focus),
       do: FormPlacement.filed(tree, focus, session.components)

  defp filed(tree, _op, _focus, _session), do: tree

  # A NUMBER THAT SAYS WHICH ONE OF THESE THIS IS. `chelekom-stepper-section` declares `step_number`
  # with a default of 1, so a fourth section dropped beside three said 1 and a duplicate of the
  # second made two 2s — and the author, who could edit the title and watch it change, had nothing to
  # change the number with. `MishkaCmsCore.Runtime.PageBuilder.Sequence` says when a run of siblings
  # is a sequence at all; a component with no such run is left exactly as it was.
  #
  # Its own list of kinds, not `@naming_kinds`: this is about a node ARRIVING beside others, which a
  # move and a delete are not — those leave a gap on purpose, because renumbering under an author
  # who is rearranging would fight them.
  @sequence_kinds [:insert, :duplicate, :paste]

  defp sequenced(tree, %{kind: kind}, focus, session) when kind in @sequence_kinds,
    do: Sequence.settle(tree, focus, session.components)

  defp sequenced(tree, _op, _focus, _session), do: tree

  # FURNISHING IS A PLACEHOLDER, AND A PLACEHOLDER GOES WHEN THE REAL THING ARRIVES. A component
  # dropped empty is a blank strip nobody can identify, so the palette puts "Your content here"
  # inside it — and nothing took the words away when an author dropped a real child in, so a list
  # placed inside a flex sat BESIDE the sentence rather than replacing it.
  #
  # Keyed off the OP and not off what is focused: `:move` focuses the node that moved, so keying on
  # focus silently skipped dragging an existing element into a furnished container — which is the
  # half the report was about. `parent_id` is set for `:insert` and `:move` alike, and `nil` means
  # the document root, which has no furnishing to remove.
  #
  # Only the exact text the palette wrote, and only when it is the ONLY remaining text: an author
  # who typed alongside it, or edited it into something of their own, keeps what they wrote.
  defp unfurnished(tree, %{kind: kind, parent_id: parent_id}, session)
       when kind in [:insert, :move] and is_binary(parent_id) do
    with %Node{kind: :component} = parent <- Tree.get(tree, parent_id),
         entry when not is_nil(entry) <- furnishing_entry(parent, session),
         furnishing when furnishing != "" <- Starter.body(entry),
         [_ | _] = placeholders <- placeholder_children(tree, parent, furnishing) do
      Enum.reduce(placeholders, tree, fn node, acc ->
        case Tree.delete(acc, node.id) do
          {:ok, trimmed} -> trimmed
          _refused -> acc
        end
      end)
    else
      _nothing_to_remove -> tree
    end
  end

  defp unfurnished(tree, _op, _session), do: tree

  defp furnishing_entry(parent, session) do
    name = Node.component_name(parent)
    Enum.find(session.components || [], &(Map.get(&1, :name) == name))
  end

  # WHAT WAS PUT THERE FOR YOU, WHATEVER SHAPE IT IS. A furnishing is markup far more often than it
  # is a sentence — `chelekom-flex` arrives as three bordered divs, a card as a heading and a
  # paragraph — and matching one text child against the whole body recognised the placeholder only
  # on the handful whose furnishing is a bare run of words. On every other component the sample
  # content stayed exactly where the author had just dropped their own, which is what was reported.
  #
  # Compared as SOURCE rather than walked: the serializer writes a subtree back the way it was
  # parsed and neither side carries a node id, so a nested furnishing is one string comparison. The
  # placeholder is still there only while every one of its roots is UNTOUCHED and something else has
  # joined them — edit one word of the sample and it is yours, and nothing removes it.
  defp placeholder_children(tree, parent, furnishing) do
    children = parent.children |> Enum.map(&Tree.get(tree, &1)) |> Enum.reject(&is_nil/1)
    planted = planted_sources(furnishing)
    real = Enum.reject(children, &blank?/1)

    with [_ | _] <- planted,
         true <- length(real) > length(planted) do
      planted_run(tree, real, planted)
    else
      _untouched_or_already_replaced -> []
    end
  end

  # IN ORDER, BUT NOT SHOULDER TO SHOULDER. A drop lands at the index it was aimed at, and aiming
  # into the middle of the sample is as ordinary as aiming above it — so the roots are matched as a
  # subsequence. Requiring them to be adjacent left the whole furnishing in place whenever the new
  # content parted it.
  #
  # What comes back is only the roots themselves. Nothing between them is touched, because on this
  # path the thing between them is exactly what the author has just put there.
  defp planted_run(tree, real, planted) do
    {matched, unmet} =
      Enum.reduce(real, {[], planted}, fn
        node, {taken, [head | rest] = expected} ->
          case source_of(tree, node) == head do
            true -> {[node | taken], rest}
            false -> {taken, expected}
          end

        _node, {taken, []} ->
          {taken, []}
      end)

    case unmet do
      [] -> Enum.reverse(matched)
      _incomplete -> []
    end
  end

  defp planted_sources(furnishing) do
    case Tree.parse(furnishing) do
      {:ok, tree} ->
        tree |> Tree.children(:root) |> Enum.reject(&blank?/1) |> Enum.map(&source_of(tree, &1))

      _unparseable ->
        []
    end
  end

  defp source_of(tree, node) do
    tree
    |> Tree.subtree(node.id)
    |> Serializer.serialize()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp blank?(%Node{kind: :text, text: text}), do: String.trim(text || "") == ""
  defp blank?(_node), do: false

  # RENUMBERING BELONGS AT THE OP LAYER, not at one insert route. Duplicate and paste are how an
  # author actually makes the second form on a page, and neither passes through `insert_at/4`:
  # `Tree.duplicate/2` mints fresh node ids and copies every attribute verbatim, so the copy arrives
  # answering to the original's DOM id, param name, page assign and both event names at once — and
  # its fields answering to the original's keys.
  #
  # WHICH ONE IS RENAMED IS DECIDED BY WHAT THE OP CREATED, not by document order: a form dropped
  # ABOVE an existing one is first in the document, and renaming it renamed the form the author had
  # already written a handler for.
  #
  # A form parsed again within one change (a delete then an insert of its ancestor's markup) answers
  # the event names the page carried at the start, so it keeps them (`Naming.dedupe/3`).
  defp deduped(tree, %{kind: kind}, previous, start) when kind in @naming_kinds do
    arrived = arrived(tree, previous)

    tree
    |> Naming.dedupe(arrived, PageForms.events(start))
    |> Naming.rekey(arrived)
    |> Ids.dedupe(arrived)
  end

  # A moved field takes a new key when it lands in another form that already uses its key.
  defp deduped(tree, %{kind: :move, node_id: id}, previous, _start) when is_binary(id),
    do: rekeyed(tree, id, form_around(previous, id) == form_around(tree, id))

  defp deduped(tree, _op, _previous, _start), do: tree

  defp rekeyed(tree, _id, true = _same_form?), do: tree
  defp rekeyed(tree, id, false), do: Naming.rekey(tree, [id | Tree.descendant_ids(tree, id)])

  defp form_around(tree, id),
    do: tree |> Tree.ancestors(id) |> Enum.find_value(&(PageForms.form?(&1) && &1.id))

  # The ids in the tree that were not in it before the op ran — exact for every kind, where the
  # focus id alone would answer only for the ones that report a created node.
  defp arrived(tree, previous),
    do: MapSet.difference(MapSet.new(Map.keys(tree.nodes)), MapSet.new(Map.keys(previous.nodes)))

  # A node that DECLARES `id` gets one when it is placed, generated once and written into the
  # template like any other attribute — so it is visible in the inspector and the author can rename
  # it. A component that declares `id` as **required** raises the moment it renders without one,
  # which used to take the whole canvas process down; generating it at the one point where nodes are
  # created means that never has to be handled later.
  #
  # Nothing else is given one. Handing an undeclared assign to a component is noise, and minting an
  # id for every `<div>` and `<p>` would rewrite a document nobody edited and fill the saved HEEx
  # with ids no rule refers to.
  # EVERY NODE THE OP CREATED, not just the one it focused. A palette entry is a worked example and
  # arrives as a SUBTREE — the kit's delete dialog brings two buttons with it — and a duplicate
  # brings a whole copy; asking only the root meant a nested component that declares `id` required
  # was placed without one and drew the "needs id" placeholder instead of rendering.
  #
  # A WRITTEN id is not touched here. On a copy it used to be replaced outright with a fresh
  # `Phoenix.LiveView.Utils.random_id/0`, which stopped the collision and cost two things worth more:
  # the author's own name for the element — `modal-delete-page` became `phx-F_3nK…` — and every
  # reference to it inside the copy, because nothing rewrote the copy's own button, label or
  # interaction to follow. `MishkaCmsCore.Runtime.PageBuilder.Ids.dedupe/2` runs over the whole tree
  # after the op and does both, for a duplicate and for a second placement from the palette alike;
  # answering it twice, in two ways, is what let the two disagree.
  defp with_id(tree, %{kind: kind}, node_id, session)
       when kind in [:insert, :duplicate, :paste] and is_binary(node_id) do
    [node_id | Tree.descendant_ids(tree, node_id)]
    |> Enum.reduce(tree, fn id, acc ->
      case Tree.get(acc, id) do
        nil -> acc
        node -> put_generated_id(acc, node, session)
      end
    end)
  end

  defp with_id(tree, _op, _focus, _session), do: tree

  defp put_generated_id(tree, node, session) do
    with true <- blank_id?(node) and takes_id?(node, tree, session),
         {:ok, updated} <- Tree.set_attr(tree, node.id, "id", {:string, generated_id()}) do
      updated
    else
      _unchanged -> tree
    end
  end

  # No `id` at all and `id=""` are the same thing — neither identifies anything, and a snippet that
  # ships an empty one is exactly as broken as one that ships none. An EXPRESSION is a value:
  # `id={@row.id}` is the author binding the id to their data, and overwriting it would break that
  # binding silently.
  defp blank_id?(node) do
    case Node.attr(node, "id") do
      nil -> true
      {:string, value} -> String.trim(value) == ""
      _expr_or_boolean -> false
    end
  end

  # The same generator the compiled components use for their own ids, so an id written here and one
  # a component mints at runtime are the same shape.
  defp generated_id, do: Phoenix.LiveView.Utils.random_id()

  # A STATEFUL COMPONENT TAKES ONE WHETHER IT DECLARES ONE OR NOT. `Phoenix.LiveView.Diff` raises
  # without an `id` on a live component, so for those the question is not what the kit wrote in its
  # `attrs` — it is the shape the component compiles into. A function component is asked the old
  # question, because minting an id it declares nothing for would put an attribute in the markup
  # that nothing reads.
  defp takes_id?(%Node{kind: :component} = node, _tree, session) do
    case Enum.find(session.components, &(&1.name == Node.component_name(node))) do
      nil -> false
      entry -> stateful?(entry) or declares_id?(entry)
    end
  end

  # A slot declares attributes of its own — `slot :item do attr :id, :string end` — and the
  # declaration lives on the component that OWNS the slot, so the parent is what has to be asked.
  # Two of the kit's slots declare `id`; the rest take none and are left alone.
  defp takes_id?(%Node{kind: :slot} = node, tree, session) do
    with %Node{} = parent <- Tree.get(tree, node.parent_id),
         %{} = entry <- Enum.find(session.components, &(&1.name == Node.component_name(parent))) do
      entry
      |> Inspector.slots()
      |> Enum.find(&(Inspector.name(&1) == Node.slot_name(node)))
      |> declares_id?()
    else
      _no_parent -> false
    end
  end

  # A plain HTML tag declares nothing, so nothing is invented for it. An `id` is still an ordinary
  # attribute anyone can type into the inspector — but minting one for every `<div>` on the page
  # would rewrite a template nobody edited, and fill the saved HEEx with ids no rule refers to.
  defp takes_id?(_node, _tree, _session), do: false

  defp stateful?(entry), do: Map.get(entry, :stateful?) == true

  defp declares_id?(nil), do: false

  defp declares_id?(declaration),
    do: Enum.any?(Inspector.attrs(declaration), &(Inspector.name(&1) == "id"))

  defp fetch_session(token) do
    case fetch(token) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, :unknown_session}
    end
  end

  # A locked node refuses every edit that targets it, and a move refuses a locked *destination* too
  # — otherwise "locked" would only mean "cannot be dragged", not "leave this alone".
  #
  # EVERY ID THE OP NAMES, not the one field most ops use. `:wrap_many` is the one that acts on a
  # selection rather than an element, and it carries `node_ids`; reading `node_id` alone meant a
  # locked element could be picked up by a multi-select and boxed anyway.
  defp authorize(session, op) do
    ids = [Map.get(op, :node_id), Map.get(op, :parent_id) | List.wrap(Map.get(op, :node_ids))]

    case Enum.any?(ids, &(is_binary(&1) and MapSet.member?(session.locked, &1))) do
      true -> {:error, gettext("That element is locked.")}
      false -> :ok
    end
  end

  defp check_containment(session, %{kind: kind} = op) when kind in [:insert, :move] do
    case subject(session, op) do
      {:ok, dragged, dragged_tree} -> can_drop(session, dragged, dragged_tree, op.parent_id)
      {:error, reason} -> {:error, reason}
    end
  end

  # A WRAP IS AN INSERT AND A MOVE WRITTEN AS ONE WORD, and an unwrap is a run of moves. They were
  # the only movements in the editor nobody asked the content model about — so the editor would put
  # a `<div>` straight into a `<ul>`, box a `<section>` inside a `<span>`, or promote a `<td>` out of
  # its row into a `<section>`, all of which a browser's parser silently rearranges, and every one of
  # which is refused the moment the same movement is spelled as a drag.
  defp check_containment(session, %{kind: :wrap, node_id: id, tag: tag}),
    do: check_wrap(session, [id], tag)

  defp check_containment(session, %{kind: :wrap_many, node_ids: ids, tag: tag}),
    do: check_wrap(session, ids, tag)

  defp check_containment(session, %{kind: :unwrap, node_id: id}), do: check_unwrap(session, id)

  defp check_containment(_session, _op), do: :ok

  # Two questions, and they are not the same one. The wrapper takes the node's PLACE, so it faces
  # every rule a drop into that parent faces — cycles and form nesting included, because that
  # position is real. The node then goes INSIDE a tag that does not exist yet, which only the rules
  # about the pair itself can be asked of.
  defp check_wrap(session, ids, tag) when is_binary(tag) do
    with {:ok, nodes} <- present(session.tree, ids),
         parent = parent_of(hd(nodes)),
         :ok <- can_drop(session, Node.new(:tag, tag: tag), nil, parent) do
      first_error(nodes, &Containment.can_hold?(&1, tag))
    end
  end

  defp check_wrap(_session, _ids, _tag), do: {:error, :unknown_node}

  # Unwrapping promotes children into the grandparent, so it is that pairing that has to hold. The
  # roles are computed once for the whole run: every child is already in this tree, so the per-drag
  # memo `Containment` would build for each of them would be the same map rebuilt N times.
  defp check_unwrap(session, id) do
    with {:ok, [node]} <- present(session.tree, [id]),
         {:ok, children} <- present(session.tree, node.children) do
      parent = parent_of(node)
      roles = Fields.roles(Tree.walk(session.tree), session.components)

      first_error(children, &can_drop(session, &1, nil, parent, roles: roles))
    end
  end

  defp present(tree, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Tree.get(tree, id) do
        nil -> {:halt, {:error, :unknown_node}}
        node -> {:cont, {:ok, acc ++ [node]}}
      end
    end)
  end

  defp parent_of(%Node{parent_id: nil}), do: :root
  defp parent_of(%Node{parent_id: parent_id}), do: parent_id

  defp first_error(items, check), do: Enum.find_value(items, :ok, &refusal(check.(&1)))

  defp refusal(:ok), do: nil
  defp refusal(error), do: error

  # THE CORE DECIDES, THEN A PLUGIN MAY TIGHTEN. An extension can refuse a placement the core allows
  # — a design system that will not have a button inside a heading — but never allow one the core
  # refused, because the core's rule is what keeps the document renderable at all.
  defp can_drop(session, dragged, dragged_tree, parent_id, extra \\ []) do
    parent = parent_id || :root

    core =
      Containment.can_drop?(
        session.tree,
        dragged,
        parent,
        Keyword.merge([components: session.components, dragged_tree: dragged_tree], extra)
      )

    case Events.containment(core == :ok, %{
           parent: parent,
           child: dragged,
           tree: session.tree,
           components: session.components
         }) do
      {:ok, true, _reason} -> core
      {:ok, false, nil} -> core
      {:ok, false, reason} -> {:error, reason}
    end
  end

  # What is being dragged, from either shape the question arrives in: a built `Op` (atom keys, on its
  # way through the mutation funnel) or the raw params of a `dragstart` (string keys, before anything
  # has been decided). Both resolve HERE so a drag hint and the check that later admits or refuses
  # that same drop can never disagree — a hint computed from a second, parallel notion of "the thing
  # being dragged" is how a blue line ends up promising a drop the server then rejects.
  #
  # THE TREE TRAVELS WITH THE NODE. A Block arrives as a `<section>` head with its own `<.form>`
  # somewhere below it, and that form lives in the PARSED TEMPLATE rather than in the document — so
  # a check handed the head alone cannot see it, and the block nests two forms silently.
  defp subject(session, %{kind: :move, node_id: id}), do: node_subject(session, id)
  defp subject(_session, %{kind: :insert, template: template}), do: template_subject(template)
  defp subject(session, %{"node_id" => id}) when is_binary(id), do: node_subject(session, id)

  defp subject(_session, %{"template" => template}) when is_binary(template),
    do: template_subject(template)

  defp subject(_session, _params), do: {:error, :unknown_node}

  defp node_subject(session, id) do
    case Tree.get(session.tree, id) do
      nil -> {:error, :unknown_node}
      node -> {:ok, node, session.tree}
    end
  end

  defp template_subject(template) do
    with {:ok, subtree} <- Tree.parse(template),
         [root | _rest] <- subtree.roots do
      {:ok, Tree.get(subtree, root), subtree}
    else
      [] -> {:error, gettext("Nothing to insert.")}
      error -> error
    end
  end

  @doc """
  Which nodes could take this drag as a child — the map the canvas paints its drop line from.

  Answered **once per drag**, at `dragstart`, rather than once per hover: the geometry of where the
  pointer is inside a box is the browser's to compute, but *whether* a drop is legal is this server's,
  and asking it per pixel of pointer travel is what a round trip per hover would mean. One call, one
  map, and the line is instant for the rest of the gesture.

  A locked node answers `false` — `authorize/2` would refuse the drop, and a hint that disagrees with
  the refusal is worse than no hint. Dragging a locked node answers `false` everywhere, for the same
  reason.

  The map is a **hint, and can go stale**: a collaborator can move the tree under a drag in flight.
  `apply_drop/2` is what actually decides.
  """
  @spec drop_hints(String.t(), map()) :: {:ok, %{String.t() => boolean()}} | {:error, term()}
  def drop_hints(token, params) do
    with {:ok, session} <- fetch_session(token),
         {:ok, dragged, dragged_tree} <- subject(session, params) do
      {:ok,
       Placement.hints(session.tree, dragged,
         components: session.components,
         dragged_tree: dragged_tree,
         locked: session.locked,
         dragged_id: params["node_id"]
       )}
    end
  end

  @doc """
  Whether the thing being dragged is a field on a Page — a template whose controls are one field, or
  a node that is part of one — so the canvas says which form it joins while it is dragged.
  """
  @spec drop_field?(String.t(), map()) :: boolean()
  def drop_field?(token, params) do
    with {:ok, session} <- fetch_session(token),
         true <- FormPlacement.page_forms?(session),
         {:ok, dragged, tree} <- subject(session, params) do
      dragging_field?(params, tree, dragged, session.components)
    else
      _not_a_field -> false
    end
  end

  defp dragging_field?(%{"node_id" => id}, tree, node, components) when is_binary(id),
    do: FormPlacement.field?(tree, node, components)

  defp dragging_field?(_template, tree, head, components),
    do: FormPlacement.arriving_field?(tree, head, components)

  @doc """
  Moves the field `node_id` belongs to into the form `target` (a node id, or
  `FormPlacement.new_target/0` for a new form with a Send button), rebinding it there, as one undo
  step. A form it leaves with no fields is removed. Answers the sentence to show. See
  `FormPlacement.move_ops/3`.
  """
  @spec move_to_form(String.t(), String.t(), String.t()) ::
          {:relocated, t(), String.t()} | {:error, term()}
  def move_to_form(token, node_id, target) do
    with {:ok, session} <- fetch_session(token),
         {:ok, ops, note} <- FormPlacement.move_ops(session, node_id, target),
         {:ok, moved} <-
           run_ops(
             token,
             &form_plan(
               FormPlacement.move_ops(&1, node_id, target),
               gettext("Moved a field to another form")
             ),
             announce: :moved
           ) do
      {:relocated, refocused(moved, ops, within_unit(session, node_id)), note}
    end
  end

  @doc """
  Moves every field of the form `from_id` into the form `into_id` and removes `from_id`, as one undo
  step, then selects `into_id`. Answers the sentence to show. See `FormPlacement.merge_ops/3`.
  """
  @spec merge_forms(String.t(), String.t(), String.t()) ::
          {:relocated, t(), String.t()} | {:error, term()}
  def merge_forms(token, from_id, into_id) do
    with {:ok, session} <- fetch_session(token),
         {:ok, _ops, note} <- FormPlacement.merge_ops(session, from_id, into_id),
         {:ok, _merged} <-
           run_ops(
             token,
             &form_plan(
               FormPlacement.merge_ops(&1, from_id, into_id),
               gettext("Moved a form's fields into another")
             ),
             []
           ),
         {:ok, merged} <- select(token, into_id) do
      {:relocated, merged, note}
    end
  end

  defp form_plan({:ok, ops, _note}, label), do: {:ok, ops, label}
  defp form_plan(refused, _label), do: refused

  @doc """
  Applies a drop, and when the position asked for is refused, puts the node **beside** the target
  rather than dropping the gesture on the floor.

  A drag paints its line from `drop_hints/2`, so reaching a refusal here means the hint was stale or
  the payload was made up. Either way the person dragging has already said where they want this, and
  "immediately after the thing you aimed at" is the answer they would pick themselves — a `<span>`
  that cannot hold a section still tells us which section the new one belongs next to.

  Returns `{:ok, session}`, `{:relocated, session, sentence}` where the sentence says what happened
  and is meant to be shown, or `{:error, reason}` when there is no room beside the target either. It
  retries **once**: a second refusal is a real one.
  """
  @spec apply_drop(String.t(), map()) ::
          {:ok, t()} | {:relocated, t(), String.t()} | {:error, term()}
  def apply_drop(token, params) do
    with {:ok, session} <- fetch_session(token) do
      dropping(token, session, Map.put(params, "kind", drop_kind(params)))
    end
  end

  # A FIELD DRAGGED FROM THE PALETTE NEVER REACHES `insert_at/4` — a drag carries its template in the
  # payload and lands here — so the form it needs is put around it on the way in. On the params
  # rather than after them, because the retry beside the target re-sends this same payload and would
  # otherwise place the field bare.
  defp dropping(token, session, params) do
    params = minted(settled_index(session.tree, anchored(session.tree, params)))

    case params["kind"] do
      "move" -> dropped_move(token, session, params)
      _insert -> dropped_insert(token, session, params)
    end
  end

  defp dropped_insert(token, session, params) do
    {params, outcome} = formed(session, params)

    case apply_op(token, params) do
      {:ok, session} -> landed(session, outcome)
      {:error, reason} -> token |> beside(params, reason) |> announced(outcome)
    end
  end

  # A form made by the retry beside the target is announced too.
  defp announced({:relocated, session, note}, outcome),
    do: {:relocated, announce_created(session, outcome), note}

  defp announced(refused, _outcome), do: refused

  # A field dragged into another form, or out of every form, is moved and rebound as one step.
  defp dropped_move(token, session, params) do
    case FormPlacement.moving(session, params) do
      {:plain, params} ->
        plain_move(token, params)

      {:run, ops, note} ->
        field_move(token, ops, note, params, within_unit(session, params["node_id"]))
    end
  end

  defp plain_move(token, params) do
    case apply_op(token, params) do
      {:ok, session} -> {:ok, session}
      {:error, reason} -> beside(token, params, reason)
    end
  end

  defp field_move(token, ops, note, params, path) do
    case apply_ops(token, ops, gettext("Moved a field to another form"), announce: :moved) do
      {:ok, session} -> {:relocated, refocused(session, ops, path), note}
      {:error, _refused} -> plain_move(token, params)
    end
  end

  # What the author is told once a placement landed, and `builder:form:after_create` for a form it
  # made.
  defp landed(session, outcome) do
    session = announce_created(session, outcome)

    case FormPlacement.told(outcome) do
      nil -> {:ok, session}
      note -> {:relocated, session, note}
    end
  end

  defp announce_created(session, :started), do: form_created(session, :started)
  defp announce_created(session, :wired), do: form_created(session, :wired)
  defp announce_created(session, _outcome), do: session

  # The form just made is the selection a placement leaves behind.
  defp form_created(session, how) do
    with %Node{} = form <- Tree.get(session.tree, session.selection),
         true <- PageForms.form?(form) do
      announce_form(session, form, how)
    else
      _no_form -> session
    end
  end

  # Every form `session` holds that did not work in `before`, announced.
  defp made_forms(session, _before, nil), do: session

  defp made_forms(session, before, how) do
    session.tree
    |> Tree.walk()
    |> Enum.filter(&(PageForms.form?(&1) and not working?(Tree.get(before, &1.id))))
    |> Enum.reduce(session, &announce_form(&2, &1, how))
  end

  defp working?(%Node{} = node), do: PageForms.form?(node)
  defp working?(nil), do: false

  # The one place `builder:form:after_create` is announced.
  defp announce_form(session, form, how) do
    Events.form_created(%{
      node_id: form.id,
      seed: PageForms.param_name(form),
      token: Naming.form_token(form),
      how: how,
      section: session.section,
      resource_id: session.resource_id,
      site_id: session.site_id,
      actor_id: session.actor_id
    })

    session
  end

  # A field moved into a new form stays the selection: the element `path` leads to under the new
  # form's first element, which is the field's unit.
  defp refocused(session, ops, path) do
    with true <- Enum.any?(ops, &(&1.kind == :insert)),
         %Node{} = form <- Tree.get(session.tree, session.selection),
         %Node{} = unit <- form |> child_nodes(session.tree) |> Enum.find(&element?/1),
         {:ok, selected} <- select(session.token, descend(session.tree, unit, path).id) do
      selected
    else
      _kept -> session
    end
  end

  # Where `node_id` sits inside the field unit it moves with, as child indexes from the unit down.
  defp within_unit(session, node_id) do
    with %Node{} = node <- Tree.get(session.tree, node_id),
         %Node{} = unit <- FormPlacement.unit(session.tree, node, session.components) do
      session.tree
      |> Tree.path(node.id)
      |> Enum.drop_while(&(&1.id != unit.id))
      |> Enum.drop(1)
      |> Enum.map(&Tree.index_of(session.tree, &1.id))
    else
      _not_a_field -> []
    end
  end

  # The node `path` leads to under `node`, as far as it leads.
  defp descend(tree, node, path) do
    Enum.reduce_while(path, node, fn at, current ->
      case Tree.get(tree, Enum.at(current.children, at)) do
        %Node{} = child -> {:cont, child}
        nil -> {:halt, current}
      end
    end)
  end

  defp child_nodes(node, tree), do: Enum.map(node.children, &Tree.get(tree, &1))

  defp element?(%Node{kind: kind}), do: kind in [:tag, :component]
  defp element?(_node), do: false

  # THE OTHER DOOR THE SAME CARD COMES THROUGH. A snippet card is the palette's hook and the
  # palette's `data-template`, so a snippet DRAGGED onto the canvas never reaches
  # `place_template/3`: its markup rides the payload to here, still wearing the `pb-xxxxxxxx`
  # classes of the document it was cut from — keys into THAT document's CSS row, which this one
  # neither owns nor prunes (`ElementScopes`). Clicking Insert and dragging are one gesture told two
  # ways and must not disagree about what the author gets.
  #
  # On the params rather than after them, for the reason the form wrapper is on them: the retry
  # beside the target re-sends this same payload, and minting once per attempt would give one drop
  # two sets of classes.
  defp minted(%{"kind" => "insert", "template" => template} = params) when is_binary(template) do
    {rescoped, _scopes} = ElementScopes.rescope(template)

    Map.put(params, "template", rescoped)
  end

  defp minted(params), do: params

  defp formed(session, %{"kind" => "insert", "template" => template} = params)
       when is_binary(template) do
    {placed, params, outcome} = FormPlacement.place(template, session, params)

    {Map.put(params, "template", placed), outcome}
  end

  defp formed(_session, params), do: {params, :none}

  defp drop_kind(%{"node_id" => id}) when is_binary(id) and id != "", do: "move"
  defp drop_kind(_params), do: "insert"

  @doc false
  # THE CANVAS COUNTS BOXES; THE TREE COUNTS CHILDREN, AND FOR A COMPONENT THOSE ARE NOT THE SAME
  # LIST. A `:slot` child renders no element of its own — `CanvasLive.slot_assigns/3` splits it out
  # and hands its children straight to the kit's `render_slot`, wherever the kit's own markup puts
  # them — so the slot costs one place in `node.children` and zero boxes on screen, while its
  # children surface among the component's own. Every index the canvas measured after a slot was
  # therefore one too low, which is why a field dropped AFTER the textarea in a form wrapper landed
  # in front of it, every time, and why the only way to reorder was to drag the other one instead.
  #
  # The layers rail never had this: `data-index` is written from `Enum.with_index(node.children)`,
  # which is the tree. So the canvas now names what it was BESIDE and the index is read here, off the
  # same list the op will be applied to. `index` stays on the payload as the fallback for an anchor
  # a collaborator deleted while the drag was in flight.
  #
  # Before `settled_index/2`, deliberately: that correction compares the dragged node's real position
  # against the index asked for, and comparing it against a screen position was half of what made the
  # move case look intermittent.
  defp anchored(tree, %{"anchor_id" => id} = params) when is_binary(id) and id != "" do
    with %Node{} = anchor <- Tree.get(tree, id),
         at when is_integer(at) <- Tree.index_of(tree, anchor.id) do
      params
      |> Map.put("parent_id", anchor.parent_id || "root")
      |> Map.put("index", at + beyond(params))
    else
      _gone -> params
    end
  end

  defp anchored(_tree, params), do: params

  defp beyond(%{"anchor_before" => true}), do: 0
  defp beyond(_params), do: 1

  @doc false
  # THE TWO SIDES COUNT DIFFERENTLY, AND ONLY ONE DIRECTION NOTICES. `Tree.move/4` reads its index
  # against the siblings with the moving node ALREADY REMOVED; the browser reads it against what is
  # on screen, where the node it is dragging is still in the row. Drag something to the right of its
  # neighbour and the two disagree by exactly one, so it lands a slot too far; drag it to the left
  # and the removal happens after the target, so nothing shifts and it is correct. Which is why it
  # reads as an intermittent bug rather than an off-by-one.
  #
  # Corrected here rather than in either client, because this is the one place that knows both the
  # payload and where the node currently sits.
  defp settled_index(tree, %{"kind" => "move", "node_id" => id, "index" => index} = params)
       when is_binary(id) do
    with %Node{parent_id: parent} = node <- Tree.get(tree, id),
         true <- same_parent?(params, parent),
         at when is_integer(at) <- Tree.index_of(tree, node.id),
         wanted when is_integer(wanted) <- to_index(index),
         true <- at < wanted do
      Map.put(params, "index", wanted - 1)
    else
      _unchanged -> params
    end
  end

  defp settled_index(_tree, params), do: params

  defp same_parent?(%{"parent_id" => "root"}, nil), do: true
  defp same_parent?(%{"parent_id" => parent}, parent) when is_binary(parent), do: true
  defp same_parent?(_params, _parent), do: false

  defp to_index(index) when is_integer(index), do: index

  defp to_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp to_index(_index), do: nil

  # What a drop retried beside its target calls a target that is not a form.
  defp beside(token, %{"parent_id" => parent_id} = params, reason) when is_binary(parent_id) do
    with {:ok, session} <- fetch_session(token),
         %Node{} = target <- Tree.get(session.tree, parent_id),
         at when is_integer(at) <- Placement.index_after(session.tree, target),
         retry = Map.merge(params, %{"parent_id" => target.parent_id, "index" => at}),
         {:ok, session} <- apply_op(token, retry) do
      where =
        Placement.spoken(target,
          components: session.components,
          other: gettext("the element you dropped it on")
        )

      {:relocated, session,
       gettext("%{reason} Placed after %{where} instead.",
         reason: sentence(reason),
         where: where
       )}
    else
      _refused -> {:error, reason}
    end
  end

  defp beside(_token, _params, reason), do: {:error, reason}

  defp sentence(reason) when is_binary(reason), do: reason
  defp sentence(_reason), do: gettext("That element could not go there.")

  defp run(op, tree) do
    case Op.apply_to(op, tree) do
      {:ok, tree, focus} -> {:ok, tree, focus}
      {:ok, tree} -> {:ok, tree, :keep}
      {:error, reason} -> {:error, reason}
    end
  end

  defp focus_on(session, :keep), do: session
  defp focus_on(session, node_id), do: %{session | selection: node_id}

  # A run that created nothing leaves the selection where `prune_ids/1` left it. Reading it off the
  # session as it was BEFORE the run — which is what `focus || session.selection` did — put back the
  # id of an element the run had just deleted.
  defp focus_run(session, nil), do: session
  defp focus_run(session, focus), do: focus_on(session, focus)

  @doc """
  Steps one entry back. Returns the session unchanged when there is nothing to undo, so a bound
  keystroke never errors.
  """
  @spec undo(String.t()) :: {:ok, t()} | {:error, term()}
  def undo(token) do
    kept = make_ref()
    run = make_ref()

    commit(
      token,
      fn session ->
        case {session.past, session.past != [] && entry_tree(session, hd(session.past))} do
          {[], _tree} ->
            {:ok, session}

          # THE STEP IS GONE. A swept or closed session can leave an entry whose patch no longer
          # exists; restoring nothing would silently blank the document, so the step is refused and
          # the entry dropped — which used to mean returning a struct nobody stored, so ETS kept the
          # dead entry and the next Ctrl+Z met it again, for ever.
          #
          # SAID ONCE IT IS STORED. A step's row is deleted only after a session without it is
          # stored, so a row missing under a change that then loses its race was taken by the write
          # it lost to. Only a change that lands read a session really pointing at nothing.
          {[_entry | rest], :error} ->
            {:store, %{session | past: rest}, {:history, :undo},
             &gone(&1, "EditorSession.undo/1")}

          {[entry | rest], {:ok, tree}} ->
            step = Journal.step_entry(session, :undo, run)

            next = %{
              session
              | tree: tree,
                revision: session.revision + 1,
                past: rest,
                future: [
                  %{entry | ref: EditorHistoryState.put(token, kept, session.tree, tree)}
                  | session.future
                ],
                selection: Journal.valid_selection(tree, session.selection),
                last_entry: nil,
                pending: Journal.queue(session.pending, step),
                step_run: step,
                dirty?: true
            }

            {:store, next, {:history, :undo}}
        end
      end,
      steps: [kept, run]
    )
  end

  @doc "Steps one entry forward."
  @spec redo(String.t()) :: {:ok, t()} | {:error, term()}
  def redo(token) do
    kept = make_ref()
    run = make_ref()

    commit(
      token,
      fn session ->
        case {session.future, session.future != [] && entry_tree(session, hd(session.future))} do
          {[], _tree} ->
            {:ok, session}

          {[_entry | rest], :error} ->
            {:store, %{session | future: rest}, {:history, :redo},
             &gone(&1, "EditorSession.redo/1")}

          {[entry | rest], {:ok, tree}} ->
            step = Journal.step_entry(session, :redo, run)

            next = %{
              session
              | tree: tree,
                revision: session.revision + 1,
                future: rest,
                past: [
                  %{entry | ref: EditorHistoryState.put(token, kept, session.tree, tree)}
                  | session.past
                ],
                selection: Journal.valid_selection(tree, session.selection),
                last_entry: nil,
                pending: Journal.queue(session.pending, step),
                step_run: step,
                dirty?: true
            }

            {:store, next, {:history, :redo}}
        end
      end,
      steps: [kept, run]
    )
  end

  defp gone(session, where) do
    Strict.violation!(where, "a history entry pointed at nothing")
    {:ok, session}
  end

  @doc """
  The document a history entry would restore.

  The entry itself carries only a reference — see `MishkaCmsCore.Runtime.States.EditorHistoryState`
  — so anything offering "go back to this", like the history rail's Revert, asks here. `:error` when
  the tree is no longer held, which a caller should treat as "that step is gone" rather than "the
  document is empty".
  """
  @spec entry_tree(t(), map()) :: {:ok, Tree.t()} | :error
  def entry_tree(%{token: token, tree: tree} = session, %{ref: ref}) do
    case EditorHistoryState.fetch(token, ref) do
      {:ok, {:tree, kept}} -> {:ok, kept}
      {:ok, {:patch, _p}} -> walk_back(token, tree, Journal.steps_to(session, ref))
      :error -> :error
    end
  end

  def entry_tree(_session, _entry), do: :error

  defp walk_back(_token, _tree, nil), do: :error

  defp walk_back(token, tree, steps) do
    Enum.reduce_while(steps, {:ok, tree}, fn %{ref: ref}, {:ok, acc} ->
      case EditorHistoryState.fetch(token, ref) do
        {:ok, {:patch, patch}} -> {:cont, {:ok, Patch.apply_to(acc, patch)}}
        {:ok, {:tree, kept}} -> {:halt, {:ok, kept}}
        :error -> {:halt, :error}
      end
    end)
  end

  @doc "How many steps back and forward are available — the `{n}/{m}` counter in the top bar."
  @spec history_counter(t()) :: {non_neg_integer(), non_neg_integer()}
  def history_counter(session),
    do: {length(session.past), length(session.past) + length(session.future)}

  # An op that produced the very same tree is not an edit. Tabbing through the style panel blurs
  # every field on the way past, each blur arriving as `set_style` with the value it already had (or
  # with none), and recording those made the user press undo once per field they walked over to take
  # back one real change. The document is still stored and re-announced — only history and the dirty
  # flag are left alone.
  @doc """
  Take the settled entries waiting to be written, and clear them from the session.

  Called by the flush, off the LiveView process. Returning them and clearing in one write is what
  stops two overlapping flushes writing the same row twice — and if the write then fails, the ids are
  stable, so re-queuing them costs nothing.
  """
  @spec drain_pending(String.t()) :: {:ok, [map()]} | {:error, term()}
  def drain_pending(token) do
    commit(
      token,
      fn session ->
        case session.pending |> Map.values() |> Enum.sort_by(& &1.at, DateTime) do
          [] ->
            {:ok, []}

          entries ->
            {:store, %{session | pending: %{}}, {:pending, :drained}, fn _ -> {:ok, entries} end}
        end
      end,
      silent: true
    )
  end

  @doc "Put entries back after a failed write, without disturbing anything queued since."
  @spec requeue(String.t(), [map()]) :: :ok
  def requeue(token, entries) do
    commit(
      token,
      fn session ->
        pending = Enum.reduce(entries, session.pending || %{}, &Map.put_new(&2, &1.id, &1))
        {:store, %{session | pending: pending}, {:pending, :requeued}}
      end,
      silent: true
    )

    :ok
  end

  @doc """
  Records the wizard's choices for a component, so its preview canvas can render them.

  Announced like everything else: the preview is a second LiveView in an iframe, and the session is
  the only thing the two share.
  """
  @spec put_wizard(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def put_wizard(token, choices) when is_map(choices),
    do: commit(token, &{:store, %{&1 | wizard: choices}, {:wizard, choices}})

  @doc """
  Selects a node, or clears the selection with `nil`.

  `origin` rides along in the broadcast because the two LiveViews answer a selection differently:
  clicking an element ON THE CANVAS is a request to work on it, so the chrome swings the left panel
  to the Inspector, while clicking a row in the layers tree is navigation and must leave the panel
  where the reader put it. Both end at the same selection; only the chrome's reaction differs.

  A plain click means "this instead", so anything held with ⌘ is let go — see `mark/2`.
  """
  @spec select(String.t(), String.t() | nil, :canvas | :panel) :: {:ok, t()} | {:error, term()}
  def select(token, node_id, origin \\ :panel) do
    commit(
      token,
      &{:store, %{&1 | selection: node_id, marked: MapSet.new()}, {:selection, node_id, origin}}
    )
  end

  @doc "Marks the hovered node — drives the canvas outline and the layers highlight."
  @spec hover(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  def hover(token, node_id),
    do: commit(token, &{:store, %{&1 | hover: node_id}, {:hover, node_id}})

  @doc "Switches the breakpoint being edited. Overrides written afterwards land in that bucket."
  @spec set_breakpoint(String.t(), atom()) :: {:ok, t()} | {:error, term()}
  def set_breakpoint(token, breakpoint) when breakpoint in @breakpoints,
    do: commit(token, &{:store, %{&1 | breakpoint: breakpoint}, {:breakpoint, breakpoint}})

  @doc "Switches the element state being edited (`:base`, `:hover`, `:focus`, `:active`)."
  @spec set_pseudo(String.t(), atom()) :: {:ok, t()} | {:error, term()}
  def set_pseudo(token, pseudo) when pseudo in @pseudos,
    do: commit(token, &{:store, %{&1 | pseudo: pseudo}, {:pseudo, pseudo}})

  @doc """
  Turns the canvas's editor overlays off and on.

  Session state for the same reason `set_dir/2` is: the thing that has to change is what the canvas
  draws — selection outlines, the floating toolbar, the expression and comment chips, the drop tail.
  Left in the chrome, the button would light up and the page would look exactly the same.
  """
  @spec set_preview(String.t(), boolean()) :: {:ok, t()} | {:error, term()}
  def set_preview(token, preview?) when is_boolean(preview?),
    do: commit(token, &{:store, %{&1 | preview?: preview?}, {:preview, preview?}})

  @doc """
  Arms (or disarms) click-to-place with a palette component's name.

  Session state rather than chrome state for the same reason `set_preview/2` is: the click that
  places the component happens inside the CANVAS, which is a different LiveView. Left in the chrome,
  the palette card would light up and clicking the page would select an element instead of placing
  anything — which is exactly what it did before this moved.
  """
  @spec pick(String.t(), String.t() | nil) :: {:ok, t()} | {:error, term()}
  # A BLOCK IS PICKED THE SAME WAY A COMPONENT IS. It arrives as `{:block, id}` so both LiveViews and
  # every placement route — a canvas click, a layer click, the tail drop zone — go on reading one
  # field and asking `picked_template/1` what to insert. Held anywhere else, the canvas simply does
  # not know a section is armed, and clicking the page does nothing while the panel says "click the
  # canvas or a layer".
  def pick(token, {:block, id} = picked) when is_binary(id),
    do: commit(token, &{:store, %{&1 | picked: picked}, {:picked, picked}})

  def pick(token, name) when is_binary(name) or is_nil(name),
    do: commit(token, &{:store, %{&1 | picked: name}, {:picked, name}})

  @doc """
  Places the armed component into `parent_id` at `index`, then disarms.

  Lives here rather than in either LiveView because both of them need it: the chrome places from the
  structure tree, the canvas from a click on the page itself, and they must not be able to disagree
  about what "the picked component" means or where it ends up.
  """
  @spec place(String.t(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:relocated, t(), String.t()} | {:error, term()}
  def place(token, parent_id, index) do
    with {:ok, session} <- fetch_session(token),
         {:ok, template} <- picked_template(session) do
      {template, spot, outcome} =
        FormPlacement.place(template, session, %{"parent_id" => parent_id, "index" => index})

      with {:ok, placed} <- insert_picked(token, template, spot["parent_id"], spot["index"]) do
        landed(placed, outcome)
      end
    end
  end

  @doc """
  Places the armed thing where a click on `node_id` means.

  A LEAF — a kit component, a heading, an image — goes inside that element when it will take one, and
  immediately after it when it will not. The fallback is the whole point. Clicking a `<.component>`
  that declares no slot, an `<img>` or an `<input>` is not a mistake — it is someone pointing at the
  place they want the new thing to appear — and answering it with "that element cannot hold children"
  puts the burden of the containment rules on them. Webflow, Elementor and Bricks all land here too.

  A BAND does not follow that rule. A band is a horizontal slice of the page and belongs beside the
  other slices, so a click pointing into one climbs out and lands after that whole branch. Without
  this, a call-to-action clicked while the page header was selected became a third item in the
  header's flex row and rendered a quarter of the width. Bricks documents Section as root-level and
  will not offer it inside a layout element; Elementor's containers refuse `section` outright.

  Returns `{:relocated, session, note}` when the landing place is neither the clicked element nor
  beside it, because that is the case the selection ring does not explain on its own. Passing `nil`
  places at the end of the document.
  """
  @spec place_at(String.t(), String.t() | nil) ::
          {:ok, t()} | {:relocated, t(), String.t()} | {:error, term()}
  def place_at(token, node_id) do
    with {:ok, session} <- fetch_session(token),
         {:ok, template} <- picked_template(session) do
      insert_at(token, template, node_id, block?(session.picked))
    end
  end

  @doc """
  Places a template that arrives without being armed first — a saved snippet, an example lifted out
  of the library, a component the wizard composed.

  Same rule as `place_at/2`, and that is the point: three routes that all mean "put this where I am
  looking" used to disagree, because this one always dropped its template beside the selection. A
  `<section>` snippet inserted while a heading deep inside a hero was selected landed inside that
  hero — the bug `place_at/2` exists to prevent, reached by another door.

  EVERY ELEMENT CLASS IN IT IS MINTED AGAIN, alongside every other placement. All three were written
  in ANOTHER document — the page a snippet was cut from, the component an example documents — so the
  `pb-xxxxxxxx` classes they carry are keys into that document's CSS row, which this one neither
  owns nor prunes (`MishkaCmsCore.Runtime.PageBuilder.ElementScopes`). The rules do NOT travel: a
  snippet stores markup and nothing else, and what the element looked like in the other document was
  that document's rule showing through the one site stylesheet. Fresh classes are what make the
  element styleable from here. Copy, paste and Duplicate are the ones that keep theirs: they stay
  inside one document, where sharing the class is the point.

  DRAGGING THE SAME CARD IS THE OTHER DOOR, and it does not come through here: a drag carries its
  markup in the payload and lands in `apply_drop/2`, which mints there for this reason.
  """
  @spec place_template(String.t(), String.t(), String.t() | nil) ::
          {:ok, t()} | {:relocated, t(), String.t()} | {:error, term()}
  def place_template(token, template, node_id),
    do: insert_at(token, template, node_id, false)

  # WHERE it lands is decided from the template as the author picked it, and only then is the form
  # written around it: `Placement` reads band-ness off the head tag, and a field wrapped first would
  # be asked about as a `<.form>` instead of as the field the author is holding.
  defp insert_at(token, template, node_id, block?) do
    with {:ok, session} <- fetch_session(token),
         subtree = Placement.subtree(template),
         head = Placement.head(subtree),
         opts = [components: session.components, dragged_tree: subtree, band?: block?],
         {parent_id, index} = Placement.target(session.tree, head, node_id, opts),
         {template, spot, outcome} =
           FormPlacement.place(template, session, %{"parent_id" => parent_id, "index" => index}),
         {:ok, placed} <- insert_picked(token, template, spot["parent_id"], spot["index"]) do
      placed(placed, Placement.relocation(session.tree, head, node_id, parent_id, opts), outcome)
    end
  end

  defp placed(session, nil, outcome), do: landed(session, outcome)

  defp placed(session, sentence, outcome),
    do: {:relocated, announce_created(session, outcome), sentence}

  # Elements are looked up first in `picked_template/1` and their ids are namespaced (`el-…`), so a
  # block id is the only thing that answers here.
  defp block?({:block, id}), do: block(id) != nil

  defp block?(_picked), do: false

  # ONE ARMED SLOT, TWO LIBRARIES. An element and a section are picked, carried and placed by exactly
  # the same route — they differ only in what they insert — so the canvas, the layers rail and the
  # tail drop zone need to know nothing about the distinction. Elements are looked up first because
  # their ids are namespaced (`el-…`) and cannot collide with a block's.
  defp picked_template(%{picked: {:block, id}}) do
    case element(id) || block(id) do
      nil -> {:error, :unknown_node}
      entry -> {:ok, template_of(entry)}
    end
  end

  # THIS SITE'S ANSWER, not the kit's. Every button here may be outlined and every alert `danger`;
  # `Presets` is where a site says so once instead of it being retyped after every drop.
  defp picked_template(%{picked: name, components: components} = session)
       when is_binary(name) do
    case Enum.find(components, &(&1.name == name)) do
      nil -> {:error, :unknown_node}
      entry -> {:ok, Presets.template(entry, session.site_name, session.site_id, components)}
    end
  end

  defp picked_template(_session), do: {:error, :nothing_picked}

  # A PLUGIN'S CARD IS A CARD. The palette draws each library merged with what extensions contribute
  # to it, so both are read back through the same merged list: reading the core library alone
  # answered "that element is no longer on the page" for an extension's card, while dragging the very
  # same card worked, because a drag carries its template in the payload and never needs the lookup.
  defp element(id), do: Events.fetch(:elements, Elements.all(), id)

  defp block(id), do: Events.fetch(:blocks, MishkaCmsCore.Runtime.PageBuilder.Blocks.all(), id)

  defp template_of(%{template: template}), do: template
  defp template_of(%{"template" => template}), do: template

  # WHERE EVERY CLICKED PLACEMENT MEETS, and so where the element classes are minted for all three:
  # `place/3` from the structure tree, `place_at/2` from a click on the page, `place_template/3` for
  # a template that arrives unarmed. The markup was written somewhere else — a snippet's page, a
  # component's example, a package's block — and its `pb-xxxxxxxx` classes are keys into THAT
  # document's element CSS row, which this one neither owns nor prunes (`ElementScopes`).
  #
  # Here rather than at the three callers because the server cannot tell the cards apart: a snippet
  # card is the palette's hook and the palette's `data-template`, and a package contributes blocks
  # through the same door core's own arrive by. Minting whatever comes through is the answer that
  # cannot be wrong; keeping a class is only ever right for markup already inside this document, and
  # nothing inside it is placed this way — `paste/2` is, and goes nowhere near here.
  #
  # `apply_op/2` is one step further down and is deliberately NOT the place: undo and redo replay
  # these ops, and minting on replay would hand the author different classes than the ones they
  # styled.
  defp insert_picked(token, template, parent_id, index) do
    {rescoped, _scopes} = ElementScopes.rescope(template)

    with {:ok, _session} <-
           apply_op(token, %{
             kind: :insert,
             template: rescoped,
             parent_id: parent_id,
             index: index
           }) do
      pick(token, nil)
    end
  end

  # A SLICE OF THE PAGE, DECIDED TWO WAYS. Two tags say it on their own: a `<section>` is what every
  # builder calls a page band, and there is one `<main>`. `article`, `aside` and `nav` are sectioning
  # content too and are deliberately absent — a `<nav>` inside a `<header>`, an `<aside>` inside an
  # `<article>` and a row of `<article>` cards inside a `<section>` are each exactly what the author
  # meant, and climbing out would fight every one of them.
  #
  # `header` and `footer` are absent for a sharper reason: they are page landmarks AND parts of a
  # section, and the spec puts them inside `<article>` as readily as at the top. Calling them bands
  # made "give this section its own header" impossible to do by clicking. The page footer in the
  # Blocks library still climbs, because the LIBRARY is what makes it a band — every entry in it is a
  # slice of the page by construction, which is the same thing Bricks means by listing Section as
  # root-level.
  @doc """
  Switches the writing direction the CANVAS is rendered in.

  Session state rather than chrome state, because the thing that has to flip is the document being
  edited — an author checking a Persian or Arabic page wants the page mirrored, not the editor around
  it. Riding on the session is what gets it into the iframe without reloading the canvas.
  """
  @spec set_dir(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def set_dir(token, dir) when dir in ~w(ltr rtl),
    do: commit(token, &{:store, %{&1 | dir: dir}, {:dir, dir}})

  @doc """
  Hands the canvas the compiled per-element CSS, so the frame paints it immediately.

  The rules themselves live in a stylesheet row — see
  `MishkaCmsCore.Runtime.PageBuilder.ElementCss` — and reach the published page through the
  compiler. This is the editor's copy, and nothing reads it but the canvas.
  """
  @spec set_element_css(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def set_element_css(token, css) when is_binary(css),
    do: commit(token, &{:store, %{&1 | element_css: css}, {:element_css, css}})

  @doc """
  Holds one element's CSS for the publish to write, a blank body holding the clearing of it.

  Read out of the session rather than merged in by the caller, because two browsers share one
  session: a caller that put its own map back would drop whatever the other one applied between.
  """
  @spec stage_element_css(String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def stage_element_css(token, scope, body) when is_binary(scope) and is_binary(body) do
    commit(token, fn session ->
      held = Map.put(session.staged_element_css || %{}, scope, body)
      {:store, %{session | staged_element_css: held}, {:staged_element_css, held}}
    end)
  end

  @doc "Drops the hold, which only the publish that has written it may do."
  @spec unstage_element_css(String.t()) :: {:ok, t()} | {:error, term()}
  def unstage_element_css(token),
    do: commit(token, &{:store, %{&1 | staged_element_css: nil}, {:staged_element_css, nil}})

  @doc """
  The bucket a style edit is written to — the width AND the state the panel is showing.

  It used to be one or the other: the breakpoint while Normal was selected, the state otherwise. So a
  hover colour set with the panel on Mobile was written to `:hover`, which is every width, and
  changed the desktop with it. There was no way at all to say "on a phone, when touched".

  `Styles.bucket/2` composes them. A state at the widest breakpoint keeps its own name, because
  `hover:` with no media query already applies everywhere — so the cheap case stays cheap: set a
  hover on Desktop and it holds on a phone unless the phone says otherwise.
  """
  @spec write_bucket(t()) :: atom()
  def write_bucket(%{pseudo: pseudo, breakpoint: breakpoint}),
    do: MishkaCmsCore.Runtime.PageBuilder.Tree.Styles.bucket(breakpoint, pseudo)

  @doc "Locks or unlocks a node. A locked node refuses selection-driven edits and moves."
  @spec toggle_lock(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def toggle_lock(token, node_id),
    do: commit(token, &{:store, %{&1 | locked: toggle(&1.locked, node_id)}, {:lock, node_id}})

  @doc """
  Flips a node's eye: draws one that was folded away, folds one that was drawn.

  Hidden is **session state, not document state**: it is the layers panel's eye toggle, a way to get
  a fixed header out of the way while working underneath it. It is deliberately not serialized, so
  saving never silently drops an element an author only meant to stop looking at.

  The set holds the ids whose eye differs from the default for their kind — see
  `MishkaCmsCore.Runtime.PageBuilder.Tree.Node.hidden?/2`. Membership therefore reads as "folded" for
  an element and "drawn" for a comment, which is why nothing outside that predicate should reach into
  the set directly.
  """
  @spec toggle_hidden(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def toggle_hidden(token, node_id),
    do: commit(token, &{:store, %{&1 | hidden: toggle(&1.hidden, node_id)}, {:hidden, node_id}})

  @doc """
  Hides a node from visitors, or shows it again — see `MishkaCmsCore.Runtime.PageBuilder.Visibility`.

  Not the eye above: this is document state, one attribute in the markup, so it goes through
  `apply_op/3` like any other edit — undo, the history, the lock and the plugin hooks come with it.
  """
  @spec toggle_visibility(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def toggle_visibility(token, node_id) do
    with {:ok, session} <- fetch_session(token),
         {:ok, op} <- Visibility.toggle_op(session.tree, node_id) do
      apply_op(token, op)
    end
  end

  @doc """
  Holds an overlay open on the canvas, or lets it shut again.

  An overlay opens on its own while it is selected — see the `data-pb-overlay` rules in
  `MishkaCmsCoreWeb.Live.Admin.Builder.CanvasLive` — so pin one only to keep it open while working
  on something else, which is the case selection alone cannot express.

  Session state like `hidden`, and never serialized: a dialog left pinned is still a dialog that
  opens from its trigger on the published page.
  """
  @spec toggle_pinned(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def toggle_pinned(token, node_id),
    do: commit(token, &{:store, %{&1 | pinned: toggle(&1.pinned, node_id)}, {:pinned, node_id}})

  defp toggle(set, id) do
    case MapSet.member?(set, id) do
      true -> MapSet.delete(set, id)
      false -> MapSet.put(set, id)
    end
  end

  @doc "Whether a node is locked."
  @spec locked?(t(), String.t()) :: boolean()
  def locked?(%{locked: locked}, node_id), do: MapSet.member?(locked, node_id)

  @doc "Whether a node is folded away on the canvas — `Node.hidden?/2` explains what the set holds."
  @spec hidden?(t(), Node.t()) :: boolean()
  def hidden?(%{hidden: hidden}, %Node{} = node), do: Node.hidden?(node, hidden)

  @doc "Whether an overlay is being held open on the canvas."
  @spec pinned?(t(), String.t()) :: boolean()
  def pinned?(%{pinned: pinned}, node_id) when is_binary(node_id),
    do: MapSet.member?(pinned || MapSet.new(), node_id)

  def pinned?(_session, _node_id), do: false

  @doc ~S(Copies a subtree to the clipboard — the prototype's "Holding …" status.)
  @spec copy(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def copy(token, node_id) do
    commit(token, fn session ->
      with {:ok, label} <- clipboard_label(session, node_id) do
        next = %{session | clipboard: Tree.subtree(session.tree, node_id), clipboard_label: label}
        {:store, next, {:clipboard, :copy}}
      end
    end)
  end

  @doc "Copies a subtree and removes it."
  @spec cut(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def cut(token, node_id) do
    with {:ok, session} <- copy(token, node_id) do
      apply_op(session.token, %{kind: :delete, node_id: node_id})
    end
  end

  @doc """
  Pastes the clipboard after the current selection, or into `parent` when one is given. Refuses an
  empty clipboard rather than doing nothing silently.

  A pasted field joins the form it lands in, or starts one, as a dropped field does; that answers
  `{:relocated, session, sentence}`.
  """
  @spec paste(String.t(), keyword()) ::
          {:ok, t()} | {:relocated, t(), String.t()} | {:error, term()}
  def paste(token, opts \\ []) do
    with {:ok, session} <- fetch_session(token),
         {:ok, clipboard} <- clipboard_of(session) do
      {parent, index} = paste_target(session, opts)

      {template, spot, outcome} =
        clipboard
        |> Serializer.serialize()
        |> FormPlacement.place(session, %{"parent_id" => parent, "index" => index})

      with {:ok, pasted} <-
             apply_op(token, %{
               kind: :insert,
               template: template,
               parent_id: spot["parent_id"],
               index: spot["index"]
             }) do
        landed(pasted, outcome)
      end
    end
  end

  @doc """
  Every place a phrase appears in the document's words.

  TEXT ONLY, and that is the whole point: a page says "Contact Us" in four places and the fifth is
  a class called `contact-us`. Renaming the company should not touch the CSS, so attributes, class
  names, expressions and comments are not searched — what comes back is what a reader would call
  the page's words.

  Each hit carries the node it is in and enough of the line to be recognised, in document order.
  """
  @spec find_text(t(), String.t()) :: [%{id: String.t(), text: String.t(), count: pos_integer()}]
  def find_text(%{tree: tree}, needle) when is_binary(needle) do
    case pattern(needle) do
      nil ->
        []

      regex ->
        tree
        |> Tree.walk()
        |> Enum.filter(&(&1.kind == :text and is_binary(&1.text) and &1.text =~ regex))
        |> Enum.map(&%{id: &1.id, text: &1.text, count: length(Regex.scan(regex, &1.text))})
    end
  end

  def find_text(_session, _needle), do: []

  @doc """
  Replaces a phrase everywhere it appears, as one undo step.

  A replace-all is one gesture and has to undo like one — forty separate entries would mean forty
  presses to get back to where you were, and no way to tell which of them was the accident.
  """
  @spec replace_text(String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def replace_text(token, needle, replacement)
      when is_binary(needle) and is_binary(replacement),
      do: run_ops(token, &replacing(&1, needle, replacement), [])

  # EACH OP CARRIES A NODE'S WHOLE NEW TEXT, worked out from the text the node had — so it is worked
  # out from the stored session. Read beforehand, a word typed into one of those nodes in between was
  # replaced by the text the node held before it was typed.
  defp replacing(session, needle, replacement) do
    case {pattern(needle), find_text(session, needle)} do
      {_regex, []} ->
        {:error, gettext("Nothing matches that.")}

      {regex, hits} ->
        ops =
          Enum.map(
            hits,
            &%{
              kind: :set_text,
              node_id: &1.id,
              text: Regex.replace(regex, &1.text, replacement)
            }
          )

        {:ok, ops,
         gettext("replace %{count} × “%{needle}”",
           count: total(hits),
           needle: String.trim(needle)
         )}
    end
  end

  # CASE-INSENSITIVE, and the SAME expression does the finding and the replacing — a search that
  # shows three hits and a replace that changes one is worse than either on its own. Escaped, so a
  # phrase with a bracket in it is a phrase and not a pattern.
  defp pattern(needle) do
    case String.trim(needle) do
      "" -> nil
      query -> Regex.compile!(Regex.escape(query), "i")
    end
  end

  defp total(hits), do: Enum.reduce(hits, 0, &(&1.count + &2))

  @doc """
  Adds a node to the selection, or takes it out again — a ⌘-click.

  The FIRST one becomes the ordinary selection rather than a mark, so holding ⌘ from the start
  behaves the way clicking does. Selecting something new plainly means "and now this instead", so
  `select/3` clears the marks; only this and `clear_marks/1` write them.
  """
  @spec mark(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def mark(token, node_id) do
    commit(token, fn session ->
      case {session.selection, MapSet.member?(session.marked, node_id)} do
        {nil, _member} ->
          {:store, %{session | selection: node_id}, {:selection, node_id, :panel}}

        {^node_id, _member} ->
          {:ok, session}

        {_other, true} ->
          marks(%{session | marked: MapSet.delete(session.marked, node_id)})

        {_other, false} ->
          marks(%{session | marked: MapSet.put(session.marked, node_id)})
      end
    end)
  end

  @doc "Back to one element."
  @spec clear_marks(String.t()) :: {:ok, t()} | {:error, term()}
  def clear_marks(token), do: commit(token, &marks(%{&1 | marked: MapSet.new()}))

  @doc """
  Everything selected, in document order.

  Order matters for every caller: wrapping three cards has to keep them in the order they appear on
  the page rather than the order they were clicked, and deleting has to start from a stable list.
  """
  @spec chosen(t()) :: [String.t()]
  def chosen(%{selection: nil, marked: marked}), do: ordered(nil, marked)
  def chosen(%{selection: selection, marked: marked}), do: ordered(selection, marked)

  defp ordered(selection, marked) do
    [selection | MapSet.to_list(marked || MapSet.new())]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  One action over everything selected, as a single undo step.

  DESCENDANTS ARE DROPPED FIRST. Holding a card and something inside it and pressing Delete would
  otherwise delete the card, and then fail on a child that went with it — halting the run and
  leaving the rest of the selection untouched.
  """
  @spec bulk(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def bulk(token, action) do
    with {:ok, session} <- fetch_session(token) do
      case topmost(session.tree, chosen(session)) do
        [] -> {:error, gettext("Nothing is selected.")}
        ids -> run_bulk(token, session, action, ids)
      end
    end
  end

  # LET GO OF ON THE SESSION AS IT IS NOW, not on the one the run handed back — that copy is already
  # a write behind anything that landed after it, and storing it would put back what that write
  # changed.
  defp run_bulk(token, _session, "delete", ids) do
    ops = Enum.map(ids, &%{kind: :delete, node_id: &1})

    label =
      ngettext("delete %{count} element", "delete %{count} elements", length(ids))

    with {:ok, _session} <- apply_ops(token, ops, label) do
      commit(token, &marks(%{&1 | marked: MapSet.new(), selection: nil}))
    end
  end

  defp run_bulk(token, _session, "duplicate", ids) do
    apply_ops(
      token,
      Enum.map(ids, &%{kind: :duplicate, node_id: &1}),
      gettext("duplicate %{count}", count: length(ids))
    )
  end

  defp run_bulk(token, _session, "wrap", ids) do
    with {:ok, _session} <- apply_op(token, %{kind: :wrap_many, node_ids: ids, tag: "div"}) do
      commit(token, &marks(%{&1 | marked: MapSet.new()}))
    end
  end

  defp run_bulk(token, session, "paste_styles", ids) do
    with {:ok, look} <- styles_of(session) do
      apply_ops(
        token,
        Enum.flat_map(ids, &style_ops(&1, look)),
        gettext("paste styles onto %{count}", count: length(ids)),
        bucket: :style
      )
    end
  end

  defp run_bulk(_token, _session, _action, _ids), do: {:error, :unknown_action}

  # A node whose ancestor is also in the list is already going wherever the ancestor goes. What
  # survives comes back in DOCUMENT order — `Tree.walk/1` is depth-first from the roots — because
  # wrapping three cards has to keep the order they read in, not the order they were clicked.
  defp topmost(tree, ids) do
    set = MapSet.new(ids)
    order = tree |> Tree.walk() |> Enum.map(& &1.id)

    ids
    |> Enum.reject(&ancestor_chosen?(tree, &1, set))
    |> Enum.sort_by(fn id -> Enum.find_index(order, &(&1 == id)) || 0 end)
  end

  defp ancestor_chosen?(tree, id, set) do
    case Tree.get(tree, id) do
      %{parent_id: nil} -> false
      %{parent_id: parent} -> MapSet.member?(set, parent) or ancestor_chosen?(tree, parent, set)
      nil -> false
    end
  end

  defp link_targets(tree, node_id) do
    case Tree.get(tree, node_id) do
      nil -> {:error, :unknown_node}
      node -> targets_of(tree, node) |> refuse_nested_link(tree, node_id)
    end
  end

  defp targets_of(tree, %{kind: :tag, tag: tag} = node) do
    case Containment.parent_restricted?(tag) do
      true -> contents_of(tree, node)
      false -> [node.id]
    end
  end

  # A SLOT IS NOT AN ELEMENT. `<:item>` has to stay a direct child of the component it fills, so an
  # `<a>` put around one is not a link — it is a template that no longer compiles.
  defp targets_of(tree, %{kind: :slot} = node), do: contents_of(tree, node)

  defp targets_of(_tree, node), do: [node.id]

  defp contents_of(tree, node), do: Enum.filter(node.children, &Tree.get(tree, &1))

  # AN `<a>` INSIDE AN `<a>` IS NOT A NESTED LINK, it is a parse error the browser repairs by
  # closing the first one — so the author is told no here rather than shown a document that reads
  # back differently from the one they built.
  defp refuse_nested_link([], _tree, _node_id), do: {:error, :nothing_to_link}

  defp refuse_nested_link(targets, tree, node_id) do
    around = Enum.any?(Tree.ancestors(tree, node_id), &link?/1)

    within =
      Enum.any?(targets, fn id ->
        [id | Tree.descendant_ids(tree, id)]
        |> Enum.map(&Tree.get(tree, &1))
        |> Enum.any?(&link?/1)
      end)

    case around or within do
      true -> {:error, :already_linked}
      false -> {:ok, targets}
    end
  end

  defp link?(%{kind: :tag, tag: "a"}), do: true
  defp link?(_node), do: false

  defp marks(session), do: {:store, session, {:marked, session.marked}}

  @doc """
  One right-click menu action, whichever surface asked for it.

  The canvas and the layers rail are separate LiveViews, and a menu implemented twice is a menu that
  drifts — the same entry deleting a branch in one place and one node in the other. Both hand the
  action here instead.

  `{:open, :snippet}` is the one entry that is not an edit: saving a selection for reuse is a form,
  and the form already exists in the Studio. Each surface opens it its own way, which is the only
  part they legitimately differ on.
  """
  @spec context_action(String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:open, :snippet} | {:error, term()}
  def context_action(token, action, node_id)

  def context_action(token, "duplicate", node_id),
    do: apply_op(token, %{kind: :duplicate, node_id: node_id})

  def context_action(token, "delete", node_id),
    do: apply_op(token, %{kind: :delete, node_id: node_id})

  # A DIV, because the wrapper is a place to put things and every other choice is a claim about what
  # they mean. The tag is one field away in the inspector once it exists.
  def context_action(token, "wrap", node_id),
    do: apply_op(token, %{kind: :wrap, node_id: node_id, tag: "div"})

  def context_action(token, "unwrap", node_id),
    do: apply_op(token, %{kind: :unwrap, node_id: node_id})

  # THE LINK GOES ROUND THE WORDS, and where the words are depends on what was pointed at. Clicking
  # the text of a list item selects the `li`, because on the canvas the words ARE the item — so a
  # link put around the node itself would read `<ul><a><li>`, which no browser keeps.
  #
  # `Containment.parent_restricted?/1` is already the editor's word for "nothing may be put around
  # this one", so the two cases are one question asked of the tag: an item, a row or a cell links
  # its contents, and everything else links itself. A run of text is never restricted and needs no
  # clause of its own.
  def context_action(token, "link", node_id) do
    with {:ok, session} <- fetch_session(token),
         {:ok, targets} <- link_targets(session.tree, node_id) do
      case targets do
        [id] -> apply_op(token, %{kind: :wrap, node_id: id, tag: "a"})
        ids -> apply_op(token, %{kind: :wrap_many, node_ids: ids, tag: "a"})
      end
    end
  end

  def context_action(token, "copy", node_id), do: copy(token, node_id)
  def context_action(token, "cut", node_id), do: cut(token, node_id)
  def context_action(token, "copy_styles", node_id), do: copy_styles(token, node_id)
  def context_action(token, "paste_styles", node_id), do: paste_styles(token, node_id)

  # AFTER THE NODE YOU POINTED AT, not inside it and not wherever the selection happens to be. The
  # keyboard's paste follows the selection because that is all it has; a right-click named a place.
  def context_action(token, "paste", node_id) do
    with {:ok, session} <- fetch_session(token) do
      case Tree.get(session.tree, node_id) do
        nil ->
          {:error, :unknown_node}

        node ->
          paste(token,
            parent_id: node.parent_id || :root,
            index: elem(Placement.after_node(session.tree, node), 1)
          )
      end
    end
  end

  def context_action(_token, "snippet", _node_id), do: {:open, :snippet}
  def context_action(token, "visibility", node_id), do: toggle_visibility(token, node_id)

  def context_action(_token, _action, _node_id), do: {:error, :unknown_action}

  @doc """
  Copies how a node LOOKS, without what it says.

  A second clipboard on purpose. Styling four cards to match by copying the first one and retyping
  its words is not the same gesture as duplicating it, and one clipboard cannot hold both — copying
  a subtree to paste its look would have thrown away whatever was waiting to be pasted.

  What travels is the `class` attribute, expression and all, and the recorded per-breakpoint and
  per-state overrides. Nothing else: not the text, not the children, not the id — and not the minted
  `pb-` class, which names the element it was copied from rather than anything about its look.
  """
  @spec copy_styles(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def copy_styles(token, node_id) do
    commit(token, fn session ->
      with {:ok, label} <- clipboard_label(session, node_id) do
        node = Tree.get(session.tree, node_id)

        next = %{
          session
          | styles: %{
              class: copied_class(Node.attr(node, "class")),
              overrides: Map.get(node.meta, :styles, %{})
            },
            styles_label: label
        }

        {:store, next, {:clipboard, :styles}}
      end
    end)
  end

  @doc """
  Puts a copied look onto another node, replacing whatever it had.

  ONE UNDO STEP. Replacing a look is a clear of every bucket followed by a write of each override,
  which is a dozen ops for one gesture — through `apply_ops/4` they collapse into a single entry, so
  undo takes the card back to how it looked rather than unwinding it one property at a time.
  """
  @spec paste_styles(String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def paste_styles(token, node_id) do
    with {:ok, session} <- fetch_session(token),
         {:ok, look} <- styles_of(session) do
      apply_ops(token, style_ops(node_id, look), gettext("paste styles"), bucket: :style)
    end
  end

  # A LOOK IS NOT A NAME. The minted `pb-xxxxxxxx` is the key the source's own CSS rule is written
  # against and the `to:` of every interaction aimed at it, so a look carrying it puts the source's
  # name on the target: `Tree.scope/2` answers with the FIRST class it finds and starts giving the
  # target the source's, which takes the target's own rule out of `ElementCss.live_rules/2` and the
  # next save prunes the author's hand-written CSS away. `Tree.set_attr/4` then leaves the target's
  # own scope as the only one it wears.
  #
  # Taken off here rather than at the paste, because a look held in the clipboard is a look and the
  # bulk paste hands the same one to twenty elements.
  # An expression carries it the same way once `Tree.ensure_scope/2` has spliced a name into the
  # list, and a look that empties out is no look at all rather than an empty list.
  defp copied_class({:string, class}), do: {:string, ElementScopes.drop_scopes(class)}
  defp copied_class({:expr, source}), do: copied_expr(ElementScopes.drop_expr_scopes(source))
  defp copied_class(none), do: none

  defp copied_expr(nil), do: {:string, ""}
  defp copied_expr(source), do: {:expr, source}

  defp styles_of(%{styles: nil}), do: {:error, gettext("No styles copied yet.")}
  defp styles_of(%{styles: styles}), do: {:ok, styles}

  # The clear has to come first and has to cover every bucket: a target with a hover colour the
  # source does not have would otherwise keep it and end up looking like neither of them.
  defp style_ops(node_id, %{class: class, overrides: overrides}) do
    {kind, value} = class_value(class)

    [%{kind: :set_attr, node_id: node_id, name: "class", value: value, value_kind: kind}] ++
      Enum.map(Op.buckets(), &%{kind: :reset_styles, node_id: node_id, bucket: &1}) ++
      for {bucket, props} <- overrides, {prop, value} <- props do
        %{kind: :set_style, node_id: node_id, bucket: bucket, prop: prop, value: value}
      end
  end

  # `class={@variant}` and `class="p-4"` are different things and the difference survives the trip.
  defp class_value({:expr, source}), do: {:expr, source}
  defp class_value({:string, value}), do: {:string, value}
  defp class_value(_none), do: {:string, ""}

  defp clipboard_of(%{clipboard: nil}), do: {:error, gettext("Nothing to paste.")}
  defp clipboard_of(%{clipboard: clipboard}), do: {:ok, clipboard}

  defp clipboard_label(session, node_id) do
    case Tree.get(session.tree, node_id) do
      nil -> {:error, :unknown_node}
      node -> {:ok, node.tag || Atom.to_string(node.kind)}
    end
  end

  defp paste_target(session, opts) do
    cond do
      opts[:parent_id] ->
        {opts[:parent_id], opts[:index] || 0}

      selected = Tree.get(session.tree, session.selection) ->
        Placement.after_node(session.tree, selected)

      true ->
        {:root, length(session.tree.roots)}
    end
  end

  @doc """
  Replaces the working tree wholesale — what a save, a draft restore or a history revert does.

  Whatever arrives is renumbered first. A document typed into the code drawer, imported, or restored
  from a draft written before this rule existed can hold two forms answering to one name, and the
  page that comes out of it routes both forms' submissions to one handler.
  """
  @spec put_tree(String.t(), Tree.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def put_tree(token, %Tree{} = tree, opts \\ []),
    do: update_tree(token, fn _stored -> {:ok, tree} end, opts)

  @doc """
  Replaces the working tree with one worked out from the tree as stored — what a condition, a hook,
  a click action or an element's scope class does, none of which is an op.

  `change` is handed the stored tree and answers `{:ok, tree}` to store `tree` the way `put_tree/3`
  does, with the same options. Anything else is answered as it is and nothing is stored. It is asked
  again whenever another write lands first, so it must do nothing it cannot repeat.
  """
  @spec update_tree(String.t(), (Tree.t() -> {:ok, Tree.t()} | term()), keyword()) ::
          {:ok, t()} | {:error, term()} | term()
  # THE TREE A LIVEVIEW HOLDS IS A BROADCAST BEHIND. The chrome and the canvas each have the document
  # as it was when they last handled one, and a whole tree built from that copy put back every edit
  # stored since: words just typed on the canvas were gone from it and from the next autosave, under
  # a flash saying the condition was set. Worked out here, the change starts from the stored tree.
  def update_tree(token, change, opts \\ []) when is_function(change, 1) do
    dirty? = Keyword.get(opts, :dirty?, true)
    reason = Keyword.get(opts, :reason, :restore)
    step = make_ref()

    commit(
      token,
      fn session ->
        case change.(session.tree) do
          {:ok, %Tree{} = tree} -> replaced(session, Naming.dedupe(tree), reason, dirty?, step)
          refused -> refused
        end
      end,
      [steps: [step]] ++ opts
    )
  end

  defp replaced(session, tree, reason, dirty?, step) do
    entry = Journal.replacement_entry(session, tree, reason, step)

    next = %{
      session
      | tree: tree,
        revision: session.revision + 1,
        step_run: nil,
        past: Journal.trim_history([entry | session.past], session.token),
        future: [],
        last_entry: nil,
        selection: carried(session, tree, session.selection),
        marked: carried_all(session, tree, session.marked),
        locked: carried_all(session, tree, session.locked),
        hidden: carried_all(session, tree, session.hidden),
        pinned: carried_all(session, tree, session.pinned),
        hover: carried(session, tree, session.hover),
        pending: recorded(session.pending, entry, dirty?),
        dirty?: dirty?
    }

    {:store, next, {:tree_replaced, reason}}
  end

  # EVERY ID THE SESSION HOLDS IS STALE after a whole-document replacement. A snapshot is HEEx, and
  # parsing it back mints fresh node ids, so the element that was selected is still on screen under a
  # different name — and matching on the old one found nothing, which dropped the selection, the
  # marks, the locks and the hidden flags on every revert and every source edit.
  #
  # They travel by document address instead — `content_address/2` rather than `address/2`, because
  # the serializer indents and parsing that back turns the indentation into text nodes, which moves
  # every plain address by one the first time a flat document meets the formatter.
  #
  # AND ONLY WHEN BOTH DOCUMENTS AGREE ABOUT THE SHAPE OF THE PATH. An address is a position, so a
  # document that changed shape can have somebody else sitting where the selection was — delete the
  # first of three list items and the address that named the second names the third, in bounds and
  # under the same tag. Attaching a lock or a hide to an element the author never touched is worse
  # than attaching it to nothing, so `same_shape_at?/3` refuses the whole carry when the run of
  # children changed anywhere along the way.
  defp carried(session, tree, id) when is_binary(id) do
    with address when is_binary(address) <- Tree.content_address(session.tree, id),
         true <- Tree.same_shape_at?(session.tree, tree, address),
         found when is_binary(found) <- Tree.at_content_address(tree, address) do
      found
    else
      _gone -> nil
    end
  end

  defp carried(_session, _tree, _nothing), do: nil

  defp carried_all(session, tree, ids) do
    (ids || MapSet.new())
    |> Enum.map(&carried(session, tree, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # A WHOLE-DOCUMENT REPLACEMENT IS A CHANGE, and goes in the timeline like any other. It used to
  # reach `past` — so the editor could undo it — without ever reaching `pending`, which is what the
  # timeline is written from; reverting therefore left no trace of itself in the record.
  #
  # Loading a draft into the editor is the one replacement that is NOT a change: it is how the
  # document arrives. It is the only caller passing `dirty?: false`, which is precisely the question
  # being asked here.
  defp recorded(pending, _entry, false), do: pending || %{}
  defp recorded(pending, entry, true), do: Journal.queue(pending, entry)

  @doc """
  Records which way the author means to save — draft or published.

  Kept on the session because it decides whether a reload picks the work back up: a draft is written
  as it is made and resuming it loses nothing, while publish-mode work was never written anywhere.
  """
  @spec set_stage(String.t(), :draft | :published) :: {:ok, t()} | {:error, term()}
  def set_stage(token, stage) when stage in [:draft, :published],
    do: commit(token, &{:store, %{&1 | stage: stage}, {:stage, stage}})

  @doc """
  Marks the session saved — clears `dirty?` and stamps `saved_at`.

  `:as_of` is the revision the caller serialized before it wrote. A session that has moved past it
  holds work that write did not carry, so it keeps `dirty?` and only takes the draft the write made
  — the editor stays clean about what is really saved instead of reporting the author's newer change
  as kept. Asked here rather than by the caller because the answer has to be read in the same commit
  that stores it. Omit it when nothing can come between the serialize and this call.
  """
  @spec mark_saved(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def mark_saved(token, opts \\ []) do
    commit(token, fn session ->
      next = %{
        session
        | dirty?: overtaken?(session, Keyword.get(opts, :as_of)),
          saved_at: DateTime.utc_now(),
          draft_id: Keyword.get(opts, :draft_id, session.draft_id),
          draft_label: Keyword.get(opts, :draft_label, session.draft_label)
      }

      {:store, next, {:saved, Keyword.get(opts, :stage, :draft)}}
    end)
  end

  defp overtaken?(_session, nil), do: false
  defp overtaken?(session, revision), do: session.revision != revision

  @doc """
  Switches what the editor is editing to a draft: its content becomes the working tree, and every
  save from here — including autosave — goes to that draft.

  The history is deliberately kept. Opening a draft is a move within one editing session, not a new
  one, so undo still walks back past it; what it must NOT do is silently continue writing to
  whatever was open before, which is why `draft_id` and `draft_label` move together.
  """
  # THE TEMPLATE IS AN ARGUMENT, not a field to reach for. Three draft resources keep a `template`;
  # `ErrorPageDraft` keeps `error_pages` and has no such key, so this clause matched nothing at all
  # for the one section it mattered to — opening an error page's draft raised rather than opening it.
  # `MishkaCmsCore.Runtime.PageBuilder.Section.template/3` is what knows, and the caller asks it.
  @spec edit_draft(String.t(), map(), String.t()) :: {:ok, t()} | {:error, term()}
  def edit_draft(token, %{id: id, label: label}, template) do
    with {:ok, tree} <- Tree.parse(template) do
      commit(token, fn session ->
        next = %{
          session
          | tree: backfill_ids(tree, session.components),
            draft_id: id,
            draft_label: label,
            # OPENING A DRAFT *IS* BEING IN THE DRAFT STAGE, and the caller used to say so in a
            # second call. Two calls meant two ETS reads of the session — each one copying the whole
            # tree out — two writes, and two broadcasts to every canvas frame for one click, on the
            # one path already reported as slow. It also left a window in between where the session
            # held a draft's document under the published stage, which is a state nothing should be
            # able to observe.
            stage: :draft,
            selection: nil,
            dirty?: false,
            # THE DOCUMENT MOVED, AND THE COUNTER HAS TO SAY SO. `revision` is how anything
            # downstream tells one document from the next, and replacing the whole tree is the
            # largest move there is — yet this was the one route that changed the tree without
            # counting it.
            #
            # The canvas publishes the revision it has painted and the editor's frame overlay waits
            # for it. With the number unchanged the canvas had nothing to announce, so the overlay
            # was never told the swap had landed and sat until its own fifteen-second failsafe gave
            # up. That is the fifteen seconds — a timeout, not a render: the canvas had repainted
            # long before, and every measured stage of this path is under a second.
            revision: session.revision + 1,
            saved_at: DateTime.utc_now()
        }

        {:store, next, {:draft, :opened}}
      end)
    end
  end

  @doc "Replaces the palette metadata containment consults — re-read when a component is installed."
  @spec put_components(String.t(), list()) :: {:ok, t()} | {:error, term()}
  def put_components(token, components) do
    # Announced, not just stored: the palette now arrives AFTER the editor mounts, and the canvas
    # binds every component to a site using this list. A canvas that rendered before it landed
    # bound them against an empty palette; the broadcast is what makes it re-render with the real
    # one instead of showing the runtime's red "failed to render".
    commit(token, &{:store, %{&1 | components: components}, {:components, length(components)}})
  end

  @doc """
  Tells everyone editing this session that something changed, without changing the session.

  For state that lives OUTSIDE the session and is shared by everyone in it — review notes, which are
  rows in `MishkaCmsCore.Runtime.PageComment` rather than a field here. Both editors already listen
  on this topic for every op, so a note posted by one appearing for the other is the existing
  collaboration channel doing what it is for, rather than a second one beside it.
  """
  @spec announce(String.t(), term()) :: :ok
  def announce(token, message) when is_binary(token) do
    Phoenix.PubSub.broadcast(@pubsub, topic(token), {:builder_session, token, message})
  end

  # EVERY MUTATION PASSES THROUGH HERE, which makes it the one place worth asking whether the
  # document is still internally consistent. A `children` list naming an id that is not in `nodes`
  # costs that whole subtree at the next save — the serializer is total, so it skips what it cannot
  # find, and the result parses perfectly. In development that is now a crash at the op that caused
  # it rather than a smaller page some time later.
  #
  # AND IT IS ONE COMPARE-AND-SWAP, because a session has more than one writer. Reading it, changing
  # it and storing it let whichever process finished last put back everything it had read: the
  # history flush, draining the queue off the LiveView process, stored the session as it was before
  # an edit every screen had already been told about, and the edit was simply gone. `change` is
  # handed the session as stored and worked out again whenever another write lands first, so it does
  # nothing it cannot repeat — the `builder:node:before_*` and containment seams are questions, and
  # are asked again — and answers one of:
  #
  #   * `{:store, session, message}` — store it, announce `message`, answer `{:ok, session}`;
  #   * `{:store, session, message, then}` — the same, answering `then.(session)` instead;
  #   * anything else — store nothing, and answer that.
  #
  # What must happen once happens after the swap: the broadcast, `then`, and dropping the history
  # rows the stored session no longer points at. `:steps` names the references a change may write
  # its rows under, made before the first try so that a retry writes over its own row rather than
  # beside it.
  defp commit(token, change, opts \\ []) do
    token
    |> EditorSessionState.update(&attempt(&1, change))
    |> settle(token, Keyword.get(opts, :steps, []), opts)
  end

  defp attempt(session, change) do
    case change.(session) do
      {:store, next, message} -> stored(session, next, message, &{:ok, &1})
      {:store, next, message, then} -> stored(session, next, message, then)
      reply -> {:skip, {:unchanged, reply}}
    end
  end

  defp stored(read, next, message, then) do
    Strict.tree!(next.tree, "EditorSession#{inspect(message)}")
    {:write, next, {:stored, read, next, message, then}}
  end

  defp settle({:ok, {:stored, read, stored, message, then}}, token, steps, opts) do
    forget(token, dropped(read, stored, steps))

    if !opts[:silent], do: announce(token, message)

    then.(stored)
  end

  defp settle(outcome, token, steps, _opts) do
    forget(token, steps)
    unstored(outcome)
  end

  defp unstored({:ok, {:unchanged, reply}}), do: reply
  defp unstored(:error), do: {:error, :unknown_session}
  defp unstored({:error, :contended} = contended), do: contended

  # A STEP GOES WITH ITS ENTRY, AND NOT BEFORE THE SESSION WITHOUT IT IS STORED. Until then the
  # stored session still points at it, and a change that loses its race leaves that session exactly
  # as it was. So the rows are dropped here, by what the change took away rather than by each path
  # that takes something: an entry that was in either stack and is in neither now, and a reserved
  # reference the stored session does not hold — a step a lost try wrote, or one never needed.
  defp dropped(%{past: past, future: future}, %{past: past, future: future}, []), do: []

  defp dropped(read, stored, steps) do
    held = MapSet.new([stored.step_run[:ref] | Enum.map(stored.past ++ stored.future, & &1.ref)])

    (read.past ++ read.future)
    |> Enum.map(& &1.ref)
    |> Enum.concat(steps)
    |> Enum.reject(&MapSet.member?(held, &1))
  end

  defp forget(token, refs), do: Enum.each(refs, &EditorHistoryState.delete(token, &1))
end
