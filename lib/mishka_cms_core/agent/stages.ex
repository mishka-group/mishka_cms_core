# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages do
  @moduledoc """
  The stage kinds a receipt checks, and the contract each kind's module keeps.

  | Kind | Layer | Module |
  |---|---|---|
  | `:dispatched` | app | `MishkaCmsCore.Agent.Stages.Dispatched` |
  | `:validated` | app | `MishkaCmsCore.Agent.Stages.Validated` |
  | `:action_committed` | app | `MishkaCmsCore.Agent.Stages.ActionCommitted` |
  | `:db_read_back` | db | `MishkaCmsCore.Agent.Stages.DbReadBack` |
  | `:job_enqueued` | db | `MishkaCmsCore.Agent.Stages.JobEnqueued` |
  | `:job_done` | app | `MishkaCmsCore.Agent.Stages.JobDone` |
  | `:broadcast_published` | app | `MishkaCmsCore.Agent.Stages.BroadcastPublished` |
  | `:ui_observed` | ui | `MishkaCmsCore.Agent.Stages.UiObserved` |
  | `:side_effect` | declared | `MishkaCmsCore.Agent.Stages.SideEffect` |

  Each module's moduledoc says what `:verified` means for it and what it does not prove.

  ## Declaring a stage

  An operation (`MishkaCmsCore.Agent.Operation`) lists its stages in the order they are checked:

    * `kind` — the kind with no options, named after itself (`:db_read_back`);
    * `{kind, opts}` — with options, named after itself;
    * `{kind, name, opts}` — with a name of its own, for a second stage of one kind, such as two
      jobs or several side effects.

  A function in `opts` is a remote capture (`&MyApp.Checks.feed/1`) or `{module, fun, args}`, so a
  declaration can be built at compile time.

  ## A kind's contract

  `verify/2` gets the operation's context and the stage's options and answers with evidence, never
  with a verdict: `{:ok, observed}`, `{:mismatch, expected, observed}`, `{:error, reason}`,
  `{:skip, reason}` or `{:unverified, reason}` (see `MishkaCmsCore.Agent.Receipt.Stage.new/3`). A
  check that raises, throws or exits is a failed stage (`:raised`), and the operation's own result
  is untouched.

  The context is a map: `:id` (the receipt id), `:receipt` (the receipt so far, for its
  `started_at`), `:operation` (the declaration or `nil`),
  `:resource`, `:action`, `:changeset` (`nil` outside an Ash action), `:result` (what the work
  returned), `:subject_id`, `:site_id`, `:actor`, `:params` (what the caller passed to `track/3`,
  for checks only, never stored), `:armed` (what `arm/2` returned, by stage name) and `:stage` (the
  name of the stage being checked).
  """

  alias MishkaCmsCore.Agent.Receipt.Stage
  alias MishkaCmsCore.Agent.Redactor
  alias MishkaCmsCore.Agent.Stages

  @typedoc "A declared stage, as `normalize/1` makes it."
  @type spec :: %{
          kind: atom(),
          name: atom(),
          layer: Stage.layer(),
          key: String.t() | nil,
          module: module(),
          opts: keyword()
        }

  @typedoc "What a check answers."
  @type answer ::
          {:ok, map()}
          | {:mismatch, map(), map()}
          | {:error, atom()}
          | {:error, atom(), map()}
          | {:skip, atom()}
          | {:unverified, atom()}
          | {:unverified, atom(), map()}

  @doc "The layer the stage's evidence comes from, for these options."
  @callback layer(keyword()) :: Stage.layer()

  @doc "Checks the stage after the operation ran."
  @callback verify(map(), keyword()) :: answer()

  @doc "Prepares before the operation runs, such as subscribing to a topic. Its return is kept in the context's `:armed`."
  @callback arm(map(), keyword()) :: term()

  @doc "Lets go of what `arm/2` prepared when the stage is never checked."
  @callback disarm(term()) :: :ok

  @doc "What late evidence for this stage is matched by, such as a job's worker."
  @callback key(keyword()) :: String.t() | nil

  @optional_callbacks arm: 2, disarm: 1, key: 1

  @kinds %{
    dispatched: Stages.Dispatched,
    validated: Stages.Validated,
    action_committed: Stages.ActionCommitted,
    db_read_back: Stages.DbReadBack,
    job_enqueued: Stages.JobEnqueued,
    job_done: Stages.JobDone,
    broadcast_published: Stages.BroadcastPublished,
    ui_observed: Stages.UiObserved,
    side_effect: Stages.SideEffect
  }

  @doc "Every stage kind."
  @spec kinds() :: [atom()]
  def kinds, do: Map.keys(@kinds)

  @doc "The module of `kind`, or `nil` for a kind that does not exist."
  @spec module(atom()) :: module() | nil
  def module(kind), do: Map.get(@kinds, kind)

  @doc "A declared stage as a spec, or `:error` for one that names no kind or is malformed."
  @spec normalize(term()) :: {:ok, spec()} | :error
  def normalize(kind) when is_atom(kind), do: normalize({kind, kind, []})

  def normalize({kind, opts}) when is_atom(kind) and is_list(opts),
    do: normalize({kind, kind, opts})

  def normalize({kind, name, opts}) when is_atom(kind) and is_atom(name) and is_list(opts) do
    case module(kind) do
      nil ->
        :error

      module ->
        {:ok,
         %{
           kind: kind,
           name: name,
           layer: module.layer(opts),
           key: key(module, opts),
           module: module,
           opts: opts
         }}
    end
  end

  def normalize(_other), do: :error

  defp key(module, opts) do
    if function_exported?(module, :key, 1), do: module.key(opts), else: nil
  end

  @doc false
  # Runs `arm/2` of every spec that has one; a failing arm leaves its stage to fail when checked.
  @spec arm([spec()], map()) :: map()
  def arm(specs, ctx) do
    Map.new(
      for %{module: module, name: name, opts: opts} <- specs,
          Code.ensure_loaded?(module) and function_exported?(module, :arm, 2) do
        {name, guarded(fn -> module.arm(Map.put(ctx, :stage, name), opts) end)}
      end
    )
  end

  @doc false
  # Lets go of what was armed for stages that were never checked.
  @spec disarm([spec()], map()) :: :ok
  def disarm(specs, armed) do
    for %{module: module, name: name} <- specs,
        Map.has_key?(armed, name),
        function_exported?(module, :disarm, 1),
        do: guarded(fn -> module.disarm(Map.fetch!(armed, name)) end)

    :ok
  end

  @doc false
  # Checks one stage and builds it from the answer, timing the check. Never raises.
  @spec check(spec(), map()) :: Stage.t()
  def check(%{module: module, name: name, opts: opts} = spec, ctx) do
    started = System.monotonic_time(:microsecond)
    answer = guarded(fn -> module.verify(Map.put(ctx, :stage, name), opts) end)
    Stage.new(spec, answer, System.monotonic_time(:microsecond) - started)
  end

  @doc false
  # The stage a declared stage becomes when the operation never got to check it.
  @spec not_reached(spec()) :: Stage.t()
  def not_reached(spec), do: Stage.new(spec, {:unverified, :not_reached})

  @doc """
  Calls a check given as a remote capture or `{module, fun, args}` with `ctx` first. Used by the
  kinds whose options take a function.
  """
  @spec call(function() | {module(), atom(), list()}, map()) :: term()
  def call(fun, ctx) when is_function(fun, 1), do: fun.(ctx)

  def call({module, fun, args}, ctx) when is_atom(module) and is_atom(fun) and is_list(args),
    do: apply(module, fun, [ctx | args])

  # A check that raises, throws or exits is a failed stage, and its error is redacted.
  defp guarded(fun) do
    fun.()
  catch
    kind, reason ->
      {:error, :raised, %{error: Redactor.error(kind, reason, __STACKTRACE__).module}}
  end
end
