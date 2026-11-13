# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Receipt do
  @moduledoc """
  The evidence of one operation: what was asked, which stages were checked, what each check found,
  and the verdict those checks add up to. Built by `MishkaCmsCore.Agent.Receipts`, never by hand.

  ## Fields

    * `id` — the correlation id, `"rcpt_"` and 26 random characters. It is the read key, so it is
      not guessable.
    * `seq` — the order the receipt was stored in on this node; newer is larger.
    * `operation` — the declared operation's name, such as `"blog:blog_post:publish"`.
    * `resource`, `action` — the Ash resource and the action that ran (a master's twin included),
      or `nil` for an operation that is not an Ash action.
    * `subject_id` — the id of the record acted on. An id, never the record.
    * `site_id` — the site the record belongs to, `nil` for a global or a master's own operation.
    * `actor` — `%{id:, kind:}`, see `MishkaCmsCore.Agent.Redactor.actor/1`.
    * `source` — who asked: `:admin`, `:api`, `:agent`, `:job`, `:system` or `:test`.
    * `status` — the verdict, computed from the stages by `status/2` and never set by a caller.
    * `stages` — the `MishkaCmsCore.Agent.Receipt.Stage`s, in the order they were checked.
    * `required` — the stage names the operation declared as what "it worked" means.
    * `visibility` — the permission names whose holders may read it (the operation's areas).
    * `started_at`, `finished_at`, `elapsed_us` — wall-clock start and end, and the monotonic
      duration in microseconds.
    * `error` — the redacted failure, if the operation raised or was refused.
    * `node` — the node that ran it; receipts are kept per node.
    * `meta` — redacted scalars the caller added.

  ## Status

    * `:failed` — a stage failed. It wins over everything else.
    * `:verified` — every required stage is `:verified` and none failed. Stages that are not
      required may still be unverified or skipped: they enrich the receipt, they do not decide it.
    * `:partial` — something beyond the dispatch was verified, but not every required stage.
    * `:unverified` — nothing beyond the dispatch was verified.

  An operation with no declaration has nothing that says what "it worked" means, so its receipt is
  never `:verified`, at most `:partial`.
  """

  alias MishkaCmsCore.Agent.Receipt.Stage
  alias MishkaCmsCore.Agent.Redactor

  @type status :: :verified | :failed | :partial | :unverified
  @type source :: :admin | :api | :agent | :job | :system | :test

  @type t :: %__MODULE__{
          id: String.t(),
          seq: non_neg_integer() | nil,
          operation: String.t(),
          resource: module() | nil,
          action: atom() | nil,
          subject_id: String.t() | integer() | nil,
          site_id: String.t() | nil,
          actor: Redactor.actor(),
          source: source(),
          status: status(),
          stages: [Stage.t()],
          required: [atom()],
          visibility: [String.t()],
          started_at: DateTime.t(),
          started_mono: integer(),
          finished_at: DateTime.t() | nil,
          elapsed_us: non_neg_integer() | nil,
          error: Redactor.error() | nil,
          node: node(),
          meta: Redactor.evidence()
        }

  defstruct id: nil,
            seq: nil,
            operation: nil,
            resource: nil,
            action: nil,
            subject_id: nil,
            site_id: nil,
            actor: %{id: nil, kind: :system},
            source: :system,
            status: :unverified,
            stages: [],
            required: [],
            visibility: [],
            started_at: nil,
            started_mono: nil,
            finished_at: nil,
            elapsed_us: nil,
            error: nil,
            node: nil,
            meta: %{}

  @sources [:admin, :api, :agent, :job, :system, :test]
  @stage_statuses %{
    "verified" => :verified,
    "failed" => :failed,
    "skipped" => :skipped,
    "unverified" => :unverified
  }

  @doc "The sources a receipt names; any other is stored as `:system`."
  @spec sources() :: [source()]
  def sources, do: @sources

  @doc "A new correlation id."
  @spec new_id() :: String.t()
  def new_id,
    do:
      "rcpt_" <>
        (16 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false))

  @doc """
  The verdict of `stages` for an operation whose `required` stage names are listed. See the
  moduledoc for the rules.
  """
  @spec status([Stage.t() | %{kind: term(), name: term(), status: Stage.status()}], [term()]) ::
          status()
  def status(stages, required) do
    cond do
      Enum.any?(stages, &(&1.status == :failed)) -> :failed
      required != [] and Enum.all?(required, &verified?(stages, &1)) -> :verified
      Enum.any?(stages, &(&1.status == :verified and &1.kind != :dispatched)) -> :partial
      true -> :unverified
    end
  end

  @doc """
  `status/2` of stages and required names kept as `to_public/1` wrote them, answered as a string:
  `"verified"`, `"failed"`, `"partial"` or `"unverified"`. A consumer that saved a receipt and
  merges late stages into it asks this, so its verdict is always the core's.

      Receipt.public_status(saved["stages"], saved["required"])
      #=> "verified"
  """
  @spec public_status([map()], [String.t()]) :: String.t()
  def public_status(stages, required) when is_list(stages) and is_list(required) do
    stages
    |> Enum.map(
      &%{
        kind: public_kind(&1["kind"]),
        name: &1["name"],
        status: Map.get(@stage_statuses, &1["status"], :unverified)
      }
    )
    |> status(required)
    |> public()
  end

  defp public_kind("dispatched"), do: :dispatched
  defp public_kind(kind), do: kind

  @doc """
  `receipt` with the evidence that arrived after it was stored applied: a late stage replaces the
  unverified stage of the same kind and match key, and the status is computed again.
  """
  @spec with_late([Stage.t()], t()) :: t()
  def with_late([], receipt), do: receipt

  def with_late(late, %__MODULE__{stages: stages, required: required} = receipt) do
    stages =
      Enum.map(stages, fn stage ->
        case Enum.find(late, &late_for?(&1, stage)) do
          nil -> stage
          observed -> %{observed | name: stage.name, layer: stage.layer, limits: stage.limits}
        end
      end)

    %{receipt | stages: stages, status: status(stages, required)}
  end

  # Only a stage still waiting takes late evidence: a stage checked when the operation ran keeps
  # what it found.
  defp late_for?(%Stage{kind: kind, key: key}, %Stage{kind: kind, key: key, status: :unverified}),
    do: true

  defp late_for?(_late, _stage), do: false

  defp verified?(stages, name),
    do: Enum.any?(stages, &(&1.name == name and &1.status == :verified))

  @doc """
  `receipt` as a JSON-safe map, for an API or an MCP tool to return as it is: dates as ISO 8601,
  atoms and modules as strings.
  """
  @spec to_public(t()) :: map()
  def to_public(%__MODULE__{} = receipt) do
    %{
      "id" => receipt.id,
      "operation" => receipt.operation,
      "resource" => public(receipt.resource),
      "action" => public(receipt.action),
      "subject_id" => receipt.subject_id,
      "site_id" => receipt.site_id,
      "actor" => public(receipt.actor),
      "source" => public(receipt.source),
      "status" => public(receipt.status),
      "required" => public(receipt.required),
      "visibility" => receipt.visibility,
      "stages" => Enum.map(receipt.stages, &Stage.to_public/1),
      "started_at" => public(receipt.started_at),
      "finished_at" => public(receipt.finished_at),
      "elapsed_us" => receipt.elapsed_us,
      "error" => public(receipt.error),
      "node" => public(receipt.node),
      "meta" => public(receipt.meta)
    }
  end

  @doc false
  def public(nil), do: nil
  def public(value) when is_boolean(value), do: value

  def public(value) when is_atom(value),
    do: value |> to_string() |> String.trim_leading("Elixir.")

  def public(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def public(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def public(%Date{} = value), do: Date.to_iso8601(value)
  def public(value) when is_list(value), do: Enum.map(value, &public/1)

  def public(value) when is_map(value) and not is_struct(value),
    do: Map.new(value, fn {key, item} -> {public(key), public(item)} end)

  def public(value), do: value
end

defmodule MishkaCmsCore.Agent.Receipt.Stage do
  @moduledoc """
  One checked stage of a receipt.

    * `kind` — what was checked, one of `MishkaCmsCore.Agent.Stages.kinds/0`.
    * `name` — the name the operation declared it under (the kind itself unless the operation
      declares several of one kind, such as two jobs).
    * `key` — what late evidence for this stage is matched by (a job's worker), or `nil`.
    * `layer` — `:app`, `:db` or `:ui`: which level the evidence came from. The three are never
      mixed: a database read never verifies a UI stage, and the action's own return value never
      verifies a database stage.
    * `status` — `:verified`, `:failed`, `:skipped` (the stage does not apply, which is not a pass)
      or `:unverified` (no evidence either way).
    * `reason` — why it is not verified: `:not_reached`, `:no_observer`, `:pending`, `:timeout`,
      `:mismatch`, `:not_found`, `:raised`, `:refused`, `:invalid`, `:off`, `:undeclared` ...
    * `expected`, `observed` — what was claimed and what the independent check found, redacted.
    * `limits` — the stage kind's module, whose moduledoc says what `:verified` does not prove.
    * `at`, `elapsed_us` — when the check ended and how long it took.
  """

  alias MishkaCmsCore.Agent.Receipt
  alias MishkaCmsCore.Agent.Redactor

  @type status :: :verified | :failed | :skipped | :unverified
  @type layer :: :app | :db | :ui

  @type t :: %__MODULE__{
          kind: atom(),
          name: atom(),
          key: String.t() | nil,
          layer: layer(),
          status: status(),
          reason: atom() | nil,
          expected: Redactor.evidence() | nil,
          observed: Redactor.evidence() | nil,
          limits: module() | nil,
          at: DateTime.t(),
          elapsed_us: non_neg_integer()
        }

  defstruct kind: nil,
            name: nil,
            key: nil,
            layer: :app,
            status: :unverified,
            reason: nil,
            expected: nil,
            observed: nil,
            limits: nil,
            at: nil,
            elapsed_us: 0

  @doc """
  A stage from what its check answered. The answer is the only way to a status: a caller hands
  over evidence, never a verdict.

    * `{:ok, observed}` — verified, with what was observed;
    * `{:mismatch, expected, observed}` — failed, `:mismatch`;
    * `{:error, reason}` or `{:error, reason, observed}` — failed;
    * `{:skip, reason}` — skipped;
    * `{:unverified, reason}` or `{:unverified, reason, observed}` — unverified.

  Anything else is a check that answered nothing a receipt understands: failed, `:bad_answer`.
  """
  @spec new(map(), term(), non_neg_integer()) :: t()
  def new(%{kind: kind, name: name, layer: layer} = spec, answer, elapsed_us \\ 0) do
    {status, reason, expected, observed} = read(answer)

    %__MODULE__{
      kind: kind,
      name: name,
      key: Map.get(spec, :key),
      layer: layer,
      status: status,
      reason: reason,
      expected: Redactor.evidence(expected),
      observed: Redactor.evidence(observed),
      limits: Map.get(spec, :module),
      at: DateTime.utc_now(),
      elapsed_us: elapsed_us
    }
  end

  defp read({:ok, observed}), do: {:verified, nil, nil, observed}
  defp read({:mismatch, expected, observed}), do: {:failed, :mismatch, expected, observed}
  defp read({:error, reason}) when is_atom(reason), do: {:failed, reason, nil, nil}
  defp read({:error, reason, observed}) when is_atom(reason), do: {:failed, reason, nil, observed}
  defp read({:skip, reason}) when is_atom(reason), do: {:skipped, reason, nil, nil}
  defp read({:unverified, reason}) when is_atom(reason), do: {:unverified, reason, nil, nil}

  defp read({:unverified, reason, observed}) when is_atom(reason),
    do: {:unverified, reason, nil, observed}

  defp read(_answer), do: {:failed, :bad_answer, nil, nil}

  @doc "`stage` as a JSON-safe map, see `MishkaCmsCore.Agent.Receipt.to_public/1`."
  @spec to_public(t()) :: map()
  def to_public(%__MODULE__{} = stage) do
    %{
      "kind" => Receipt.public(stage.kind),
      "name" => Receipt.public(stage.name),
      "key" => stage.key,
      "layer" => Receipt.public(stage.layer),
      "status" => Receipt.public(stage.status),
      "reason" => Receipt.public(stage.reason),
      "expected" => Receipt.public(stage.expected),
      "observed" => Receipt.public(stage.observed),
      "limits" => Receipt.public(stage.limits),
      "at" => Receipt.public(stage.at),
      "elapsed_us" => stage.elapsed_us
    }
  end
end
