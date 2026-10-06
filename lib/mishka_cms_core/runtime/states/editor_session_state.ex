defmodule MishkaCmsCore.Runtime.States.EditorSessionState do
  @moduledoc """
  The ETS table behind the page builder's live editing sessions, keyed by session token.

  A session holds the working tree, the selection, the undo history and the clipboard — everything
  the editor needs between opening a page and saving it. Keeping it here rather than in a LiveView's
  assigns is what lets the **two** LiveViews of the editor (the chrome and the canvas inside its
  iframe) look at one document: they hold a token, not a copy.

  Crash-safe: a GenServer owns a `:named_table, :public` table and every read guards on
  `:ets.whereis/1`, so a caller that races the table's creation gets `:error` instead of an
  ArgumentError.

  ## Every change is a compare-and-swap

  One session has several writers at once — the chrome, the canvas, and the tasks each of them
  starts (the history flush, the autosave, the palette load). Each of them reads the row, works out
  the next session, and writes it back, and a plain `:ets.insert/2` at the end of that let the last
  one to finish put back everything it had read: an edit announced to every screen and then silently
  undone by a flush that had read the session a moment before it. `update/2` stamps each row with a
  version and writes only over the version it read, so a change that lost the race is worked out
  again on the session as the winner left it.

  Sessions are swept hourly: anything untouched for 24 hours is dropped. Nothing is lost by that,
  because a live session autosaves to a draft, and a draft is a real row.
  """
  use GenServer

  require MishkaCmsCore.Runtime.PageBuilder.Strict

  alias MishkaCmsCore.Runtime.PageBuilder.Strict

  require Logger

  @table :mishka_builder_sessions
  @sweep_interval :timer.hours(1)
  @max_idle :timer.hours(24)

  # A CHANGE IS WORKED OUT AGAIN ONLY WHEN ANOTHER WRITE LANDED WHILE IT WAS BEING WORKED OUT. A slow
  # one — an assistant's run over a large page — can lose a few times to an author typing beside it,
  # each keystroke an op, a flush and an autosave. Losing a thousand times in a row is not that; it
  # is a change that writes its own session while it runs, and would otherwise never stop.
  @max_attempts 1_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Fetches a session by token."
  @spec get(String.t()) :: {:ok, struct()} | :error
  def get(token) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      _tid ->
        case :ets.lookup(@table, token) do
          [{^token, session, _touched_at, _version}] -> {:ok, session}
          [] -> :error
        end
    end
  end

  @doc """
  The session this person already has open on this document, if any — the newest one.

  Reopening the editor used to mint a fresh token and rebuild from the database, so a reload, a
  crashed canvas or a mis-click threw away everything since the last save. A session survives all
  three; it was only the lookup that was missing.

  Scoped to the actor as well as the document: two people editing the same page get their own
  sessions and meet through `Presence`, which is what the locking and the collaborator list already
  assume.

  Matched over the same table rather than kept in a second index — an index would be one more thing
  to invalidate on delete and on the hourly sweep, for a table that holds tens of rows.
  """
  @spec find(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, struct()} | :error
  def find(section, resource_id, actor_id, status \\ nil)

  def find(section, resource_id, actor_id, status)
      when is_binary(section) and is_binary(resource_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      tid ->
        tid
        |> :ets.select(open_on(section, resource_id, actor_id, status))
        |> Enum.max_by(fn {_token, touched_at} -> touched_at end, fn -> nil end)
        |> newest()
    end
  end

  def find(_section, _resource_id, _actor_id, _status), do: :error

  # MATCHED INSIDE ETS, and only the token comes back. `tab2list` copied every open session in the
  # node into this process to look at three fields of each — and a session carries the document tree,
  # its undo history and the site's whole component palette, so that is megabytes per row, on a table
  # that every editor mount reads. The filter runs in the table instead, the scan returns
  # `{token, touched_at}` pairs, and exactly one session is copied out: the one being resumed.
  #
  # THE STATUS IS PART OF THE DOCUMENT for an error page, whose record holds one template per status.
  # Without it, pressing 500 in the status strip resumed the session opened on 404 — the strip lit
  # 500, the canvas kept the 404 tree, and the next publish wrote that tree into the 500 entry.
  #
  # A session stored before this field existed carries no `:status` key, so it matches nothing here
  # and a fresh one opens — the same answer an expired session already gets, and the safe one.
  defp open_on(section, resource_id, actor_id, status) do
    [
      {
        {:"$1", %{section: :"$2", resource_id: :"$3", actor_id: :"$4", status: :"$6"}, :"$5", :_},
        [
          {:andalso,
           {:andalso, {:andalso, {:==, :"$2", section}, {:==, :"$3", resource_id}},
            {:==, :"$4", actor_id}}, {:==, :"$6", status}}
        ],
        [{{:"$1", :"$5"}}]
      }
    ]
  end

  defp newest(nil), do: :error

  defp newest({token, _touched_at}) do
    case :ets.lookup(@table, token) do
      [{^token, session, _touched, _version}] -> {:ok, session}
      _gone -> :error
    end
  end

  @doc """
  Stores a new session and stamps it as touched. Returns the session unchanged so it composes into a
  pipeline; a write before the table exists is a no-op rather than a crash.

  For a session being OPENED. Anything changing a session that is already stored goes through
  `update/2`, because this writes whatever it is handed over whatever is there.

  A WRITE IS NOT A READ. Answering a missing table forgivingly is right for a read — racing the
  table's creation should not raise — but a write that goes nowhere and reports success is how an
  editor comes to believe it saved something. In development that raises, because the table is either
  up or the application is misconfigured and both are worth knowing about.
  """
  @spec put(String.t(), struct()) :: struct()
  def put(token, session) do
    case :ets.whereis(@table) do
      :undefined ->
        Strict.violation!("EditorSessionState.put/2", "the session table is not running")

      _tid ->
        :ets.insert(@table, {token, session, System.monotonic_time(:microsecond), version()})
    end

    session
  end

  @doc """
  Changes a stored session atomically.

  `change` receives the session as stored and answers `{:write, session, reply}` to store `session`,
  or `{:skip, reply}` to leave the row as it is. Either way the answer is `{:ok, reply}`; `:error`
  when there is no such session.

  The write lands only over the version `change` read. When another write landed in between, nothing
  is stored and `change` runs again on the session that write left — so `change` must do nothing it
  cannot repeat, and anything that must happen once belongs after this returns. Losing that race
  more than a bounded number of times in a row is a violation in development and
  `{:error, :contended}` otherwise.
  """
  @spec update(String.t(), (struct() -> {:write, struct(), reply} | {:skip, reply})) ::
          {:ok, reply} | :error | {:error, :contended}
        when reply: term()
  def update(token, change) when is_function(change, 1) do
    case :ets.whereis(@table) do
      :undefined -> :error
      _tid -> attempt(token, change, @max_attempts)
    end
  end

  defp attempt(_token, _change, 0) do
    Strict.violation!(
      "EditorSessionState.update/2",
      "a change kept losing to writes of its own row"
    )

    {:error, :contended}
  end

  defp attempt(token, change, attempts) do
    with [{^token, session, _touched_at, version}] <- :ets.lookup(@table, token),
         {:write, next, reply} <- change.(session) do
      case :ets.select_replace(@table, swap(token, version, next)) do
        1 -> {:ok, reply}
        0 -> attempt(token, change, attempts - 1)
      end
    else
      [] -> :error
      {:skip, reply} -> {:ok, reply}
    end
  end

  # THE VERSION IS IN THE MATCH, and the key is bound, so this is a lookup and not a scan: the row
  # is replaced only while it still carries the version the change was worked out from. The session
  # travels as a constant because a match spec would otherwise read its tuples and atoms as
  # instructions.
  defp swap(token, version, session) do
    [
      {{token, :_, :_, version}, [],
       [{{{:const, token}, {:const, session}, System.monotonic_time(:microsecond), version()}}]}
    ]
  end

  # UNIQUE, NOT MERELY LATER. A version that could repeat — a counter a re-opened session restarts,
  # a clock two writes share a tick of — would let a change read one session and land over another
  # that happens to carry the same number.
  defp version, do: System.unique_integer([:monotonic, :positive])

  @doc "Drops a session — what closing the editor does."
  @spec delete(String.t()) :: :ok
  def delete(token) do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _tid -> :ets.delete(@table, token)
    end

    :ok
  end

  @doc "How many sessions are open right now. Used by the admin runtime-health panel and by tests."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.whereis(@table) do
      :undefined -> 0
      tid -> :ets.info(tid, :size)
    end
  end

  @doc "Every open session token. Ordering is undefined."
  @spec tokens() :: [String.t()]
  def tokens do
    case :ets.whereis(@table) do
      :undefined -> []
      _tid -> :ets.select(@table, [{{:"$1", :_, :_, :_}, [], [:"$1"]}])
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

  # MICROSECONDS, matching `put/2`. `find/3` answers "the newest session on this document", and at
  # millisecond resolution two sessions opened in the same tick were tied — so which one a reload
  # resumed depended on ETS ordering. `@max_idle` is written in milliseconds, so it is scaled here
  # rather than restated.
  @impl true
  def handle_info(:sweep, state) do
    cutoff = System.monotonic_time(:microsecond) - @max_idle * 1000

    dropped =
      :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:<, :"$1", cutoff}], [true]}])

    if dropped > 0 do
      Logger.info("[EditorSessionState] swept #{dropped} idle builder session(s)")
    end

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)
end
