defmodule MishkaCmsCore.Runtime.States.EditorHistoryState do
  @moduledoc """
  What the undo history holds, kept beside the session rather than inside it.

  ## Why they are not in the session

  `MishkaCmsCore.Runtime.States.EditorSessionState` stores one row per editing session, and ETS
  copies a whole row on every read and every write. One placed component reads and writes that row
  about thirteen times.

  ## Patches, not documents

  Each row is a `MishkaCmsCore.Runtime.PageBuilder.Tree.Patch` — the nodes as they were before one
  step, and nothing else.

  It used to be a whole document per entry. In memory that is nearly free, because fifty versions
  share almost every node, but ETS discards structural sharing: a term written to a table is
  flattened, so fifty entries landed as fifty independent copies. Measured on a 5,001-node document
  that was 1.2 MB an entry and **57.5 MB for one person's session** — and the fifty-entry cap that
  bounded it was itself the bug that made the editor stop recording after fifty changes.

  A patch is proportional to what changed, not to what exists: **290 bytes** for a typical edit
  whatever the document's size, 84× to 4,160× smaller than the document it belongs to. So the depth
  of the history became a question about memory, which is answerable, instead of a count, which was
  a guess.

  ## The budget

  `@max_bytes` per session, not a number of entries. A count is wrong in both directions at once —
  fifty entries is a few minutes' work on a small page and 57 MB on a large one. A budget gives a
  small document thousands of steps and a large one as many as it can afford, and either way the
  memory a session can hold is a number you can multiply by your editor count.

      config :mishka_cms_core, builder_history_bytes: 8_388_608

  ## Reading one back

  A patch reverses one step from the version after it, so reaching a version several steps away means
  applying each patch in between. `MishkaCmsCore.Runtime.PageBuilder.EditorSession` does that walking
  because it is the thing that knows the order; here they are only stored and fetched by reference.
  Measured at 79 µs for a hundred steps.

  Same crash-safe shape as its sibling: a GenServer owns a `:named_table, :public` table and every
  read guards on `:ets.whereis/1`, so racing the table's creation returns `:error` rather than
  raising. Rows are dropped with their session, and swept hourly for any session that vanished
  without saying so.
  """
  use GenServer

  require Logger
  require MishkaCmsCore.Runtime.PageBuilder.Strict

  alias MishkaCmsCore.Runtime.PageBuilder.Tree
  alias MishkaCmsCore.Runtime.PageBuilder.Strict
  alias MishkaCmsCore.Runtime.PageBuilder.Tree.Patch
  alias MishkaCmsCore.Runtime.States.EditorSessionState

  @table :mishka_builder_history
  @sweep_interval :timer.hours(1)

  # 8 MB of patches per session. Measured: a typical edit is 290 B whatever the document's size, so
  # this is tens of thousands of steps on an ordinary page — far past what anyone reaches in a
  # sitting — while still bounding what one session can hold.
  @default_max_bytes 8_388_608

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The memory one session's history may hold, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes,
    do: Application.get_env(:mishka_cms_core, :builder_history_bytes, @default_max_bytes)

  @doc """
  Remembers `before` as one step back from `during` under `ref`, and returns `ref`.

  Both documents are wanted because a patch is the difference between them; the caller has each of
  them at the moment it decides to remember one, and asking for both here is what keeps this from
  having to guess what the previous version was.

  The reference is the CALLER'S, made with `make_ref/0` before the change that records it is first
  tried. A session change can be worked out more than once — see
  `MishkaCmsCore.Runtime.States.EditorSessionState.update/2` — and a reference minted here on every
  try left a row behind for each try that lost. Writing under one the caller already holds replaces
  what it remembered instead, so a retry costs nothing and leaves nothing.
  """
  @spec put(String.t(), reference(), Tree.t(), Tree.t()) :: reference()
  def put(token, ref, %Tree{} = before, %Tree{} = during) when is_reference(ref) do
    patch = Patch.build(before, during)
    write(token, ref, {:patch, patch}, Patch.bytes(patch), "EditorHistoryState.put/4")
  end

  @doc """
  Remembers a whole document under `ref`, and returns `ref`.

  For the steps that do not sit in the undo stack at all — the row an undo RUN writes, which
  describes net movement rather than one transition. A patch only means something relative to the
  version after it, and those have no version after them, so they keep the document itself.

  Rare by construction: one per run of undos, not one per change. The reference is the caller's for
  the reason `put/4` gives.
  """
  @spec keep(String.t(), reference(), Tree.t()) :: reference()
  def keep(token, ref, %Tree{} = tree) when is_reference(ref) do
    bytes = byte_size(:erlang.term_to_binary(tree))
    write(token, ref, {:tree, tree}, bytes, "EditorHistoryState.keep/3")
  end

  # THE RUNNING TOTAL IS KEPT, NOT COUNTED. The budget is checked on every recorded step, and a
  # session deep enough to be worth a budget is one where summing its rows each time is the expensive
  # part. It rides the same table under `{token, :bytes}`; every select here guards on the key's
  # second element being a reference, so the counter never answers as a step.
  defp write(token, ref, remembered, bytes, where) do
    case :ets.whereis(@table) do
      :undefined ->
        Strict.violation!(where, "the history table is not running")

      _tid ->
        # THE OLD SIZE IS READ FIRST, and taken off. A reference written again — a change tried a
        # second time — is charged for what it holds now rather than twice, and asking after the
        # write would read back what was just stored, so the difference would always be nothing.
        delta = bytes - was(token, ref)
        :ets.insert(@table, {{token, ref}, remembered, bytes})
        bump(token, delta)
    end

    ref
  end

  defp was(token, ref) do
    case :ets.lookup(@table, {token, ref}) do
      [{{^token, ^ref}, _patch, bytes}] -> bytes
      [] -> 0
    end
  end

  defp bump(_token, 0), do: :ok

  defp bump(token, delta) do
    :ets.update_counter(@table, {token, :bytes}, {2, delta}, {{token, :bytes}, 0})
    :ok
  end

  @doc """
  What a reference remembers — `{:patch, patch}` for a step in the stack, `{:tree, tree}` for one
  that stands alone — or `:error`.

  `:error` is a real answer rather than a crash: the sweep, a closed session or a step dropped for
  the budget can all take a row away, and an undo that finds nothing should leave the document alone
  rather than take the editor down.
  """
  @spec fetch(String.t(), reference()) :: {:ok, {:patch, Patch.t()} | {:tree, Tree.t()}} | :error
  def fetch(token, ref) when is_reference(ref) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      _tid ->
        case :ets.lookup(@table, {token, ref}) do
          [{{^token, ^ref}, remembered, _bytes}] -> {:ok, remembered}
          [] -> :error
        end
    end
  end

  def fetch(_token, _ref), do: :error

  @doc "Drops one step — what falls off the far end when a session is over its budget."
  @spec delete(String.t(), reference()) :: :ok
  def delete(token, ref) when is_reference(ref) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        bump(token, -was(token, ref))
        :ets.delete(@table, {token, ref})
    end

    :ok
  end

  def delete(_token, _ref), do: :ok

  @doc "Drops every step a session kept — what closing the editor does."
  @spec delete_all(String.t()) :: :ok
  def delete_all(token) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _tid ->
        :ets.match_delete(@table, {{token, :_}, :_, :_})
        :ets.delete(@table, {token, :bytes})
    end

    :ok
  end

  @doc """
  What this session's history is holding, in bytes.

  What the budget is measured against, and what the runtime-health panel reports.
  """
  @spec bytes(String.t()) :: non_neg_integer()
  def bytes(token) do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _tid ->
        case :ets.lookup(@table, {token, :bytes}) do
          [{{^token, :bytes}, bytes}] -> bytes
          [] -> 0
        end
    end
  end

  @doc """
  What one step is holding, in bytes — `0` for one that is not held.

  What trimming counts down by: the steps it drops are deleted only once the session that forgot
  them is stored, so the total cannot be asked again after each one.
  """
  @spec bytes(String.t(), reference()) :: non_neg_integer()
  def bytes(token, ref) when is_reference(ref) do
    case :ets.whereis(@table) do
      :undefined -> 0
      _tid -> was(token, ref)
    end
  end

  def bytes(_token, _ref), do: 0

  @doc "How many steps are held right now, across every session. For the health panel and tests."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.whereis(@table) do
      :undefined ->
        0

      _tid ->
        :ets.select_count(@table, [
          {{{:_, :"$1"}, :_, :_}, [{:is_reference, :"$1"}], [true]}
        ])
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    schedule_sweep()
    {:ok, %{}}
  end

  # ORPHANS ONLY. A session that closes cleanly takes its history with it; this is for the ones that
  # do not — a node that went down mid-edit, a session the sibling table swept for idleness. Anything
  # whose token no longer has a session cannot be read by anybody again.
  @impl true
  def handle_info(:sweep, state) do
    live = MapSet.new(EditorSessionState.tokens())

    dropped =
      case :ets.whereis(@table) do
        :undefined ->
          0

        _tid ->
          @table
          |> :ets.select([{{{:"$1", :_}, :_, :_}, [], [:"$1"]}])
          |> Enum.uniq()
          |> Enum.reject(&MapSet.member?(live, &1))
          |> Enum.map(&delete_all/1)
          |> length()
      end

    if dropped > 0 do
      Logger.info("[EditorHistoryState] swept the history of #{dropped} closed session(s)")
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
