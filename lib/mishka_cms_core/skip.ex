# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Skip do
  @moduledoc """
  Skipping a failure: the one way every part of the CMS lets an admin say "we do not want to try
  this again". The core's background jobs use it (the activity log's failed jobs), and so does an
  extension's own failure, such as a provider event not handled or a webhook delivery given up.

  ## What a skip means

    * The item keeps its row. It shows a grey **Skipped** badge where a failure shows a red
      **Failed** one, and its list has a Skipped filter beside Failed.
    * It is never tried again: its scheduled retries are cancelled (`skip_jobs/2`) and the job that
      would run it finds it no longer applies.
    * It stops counting as an open problem at once, everywhere: the sidebar's status lines, the
      menu badges, the bell's What needs you and the notifications about it (`changed/1`).
    * It records who skipped it, when and, when given, why (`mark/2`): a short optional reason of
      at most `reason_max/0` characters.
    * **Bring back** undoes it: the item is a failure again, counts again and waits for a person. It
      is not tried again by itself; the item's own Run again does that.

  ## The fields

  A resource whose rows can be skipped carries three attributes, named so everywhere:

      attribute :skipped_at, :utc_datetime_usec, public?: true
      attribute :skipped_by_id, :uuid, public?: true
      attribute :skip_reason, :string, public?: true, constraints: [max_length: 200]

  and, when it has a state, a `:skipped` value of it (a failure is `:failed`). A list's "open
  problems" count is then `status == :failed` (or `is_nil(skipped_at)` for a resource with no
  state), so a skipped row drops out of every count with no other change.

  ## The actions

  Two update actions, `:skip` and `:bring_back`, with the changes of this module:

      update :skip do
        require_atomic? false
        argument :reason, :string
        change {MishkaCmsCore.Skip.Changes.Skip,
                status: {:status, :skipped}, from: [:failed], source: "shop:delivery",
                worker: MyShop.Delivery.Worker}
      end

      update :bring_back do
        require_atomic? false
        change {MishkaCmsCore.Skip.Changes.BringBack,
                status: {:status, :failed}, source: "shop:delivery", worker: MyShop.Delivery.Worker}
      end

  `MishkaCmsCore.Skip.Changes.Skip` refuses a row that is not one of `from`, writes the three fields
  from the actor and the `reason` argument, sets the state, cancels the row's AshOban jobs of
  `worker` and, once committed, calls `changed/1`. `MishkaCmsCore.Skip.Changes.BringBack` refuses a
  row that is not skipped, clears the fields, sets the state back, makes the row's cancelled jobs
  failed jobs again and calls `changed/1`. A page asks for the reason in its question window, shows
  an Undo toast after a skip (which runs `:bring_back`) and a Bring back button on a skipped row.

  A failure that is not an Ash row (the core's Oban jobs) uses `skip_jobs/2`, `bring_back_jobs/1`
  and `changed/1` directly (`MishkaCmsCore.Activity.Sources.Oban.skip/3`).

  ## Telling the rest of the CMS

  `changed/1` is called after every skip and bring back. It:

    * marks read the unread notifications about the item (on a skip): a producer that tells the
      bell about a failure puts `metadata: %{"failure" => MishkaCmsCore.Skip.key(source, id)}` on
      it, and those rows leave the bell's count;
    * tells the sidebar's status row and the bell's What needs you to count the item's site again
      (`MishkaCmsCore.Layouts.SidebarStatus.changed/1`, `MishkaCmsCore.Layouts.TopbarNeeds.changed/1`);
    * fires the mishka_installer event `"failure:skip:changed"` (`event/0`) with
      `%{source:, id:, site_id:, skipped?:, reason:, actor_id:}`, so a plugin can follow: clean what it
      keeps about the item, recount its own menu badge.

  ## Telemetry

    * `[:mishka_cms, :skip, :changed]`: measurements `%{count: 1}`, metadata `%{source:, id:,
      site_id:, skipped?:}`, emitted by `changed/1`.
  """

  require Ash.Query
  require Logger

  import Ecto.Query, only: [from: 2, where: 3]

  @reason_max 200
  @event "failure:skip:changed"
  @open_job_states ~w(available scheduled retryable)

  @typedoc "What `changed/1` is told about one skip or bring back."
  @type change :: %{
          required(:source) => String.t(),
          required(:id) => String.t(),
          required(:skipped?) => boolean(),
          optional(:site_id) => String.t() | nil,
          optional(:reason) => String.t() | nil,
          optional(:actor_id) => String.t() | nil
        }

  @doc "The longest skip reason, in characters."
  @spec reason_max() :: pos_integer()
  def reason_max, do: @reason_max

  @doc "The mishka_installer event `changed/1` fires."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The reason as it is kept: trimmed, cut to `reason_max/0` characters, and `nil` when nothing is
  left.

      iex> MishkaCmsCore.Skip.reason("  the buyer paid by bank  ")
      "the buyer paid by bank"
      iex> MishkaCmsCore.Skip.reason("   ")
      nil
  """
  @spec reason(term()) :: String.t() | nil
  def reason(text) when is_binary(text) do
    case text |> String.trim() |> String.slice(0, @reason_max) do
      "" -> nil
      kept -> kept
    end
  end

  def reason(_none), do: nil

  @doc "The three fields of a skip by `actor` (a map with an `id`, or `nil`) with `reason`."
  @spec mark(map() | nil, term()) :: %{
          skipped_at: DateTime.t(),
          skipped_by_id: String.t() | nil,
          skip_reason: String.t() | nil
        }
  def mark(actor, reason) do
    %{skipped_at: DateTime.utc_now(), skipped_by_id: actor_id(actor), skip_reason: reason(reason)}
  end

  @doc "The three fields of a row brought back: all empty."
  @spec cleared() :: %{skipped_at: nil, skipped_by_id: nil, skip_reason: nil}
  def cleared, do: %{skipped_at: nil, skipped_by_id: nil, skip_reason: nil}

  @doc """
  The name of one failure across the CMS, `"<source>:<id>"`: what a notification about it carries in
  its `metadata["failure"]`.
  """
  @spec key(String.t(), String.t()) :: String.t()
  def key(source, id), do: "#{source}:#{id}"

  @doc """
  The Oban jobs of one row worked by AshOban `worker` (the trigger's `worker_module_name`), as an
  `Oban.Job` query for `skip_jobs/2` and `bring_back_jobs/1`.
  """
  @spec record_jobs(module(), String.t()) :: Ecto.Query.t()
  def record_jobs(worker, id) do
    worker = inspect(worker)

    from(j in Oban.Job,
      where: j.worker == ^worker and fragment("?->'primary_key'->>'id' = ?", j.args, ^id)
    )
  end

  @doc """
  Skips the jobs of `query` (an `Oban.Job` query) in one statement: a job still waiting to run
  (`available`, `scheduled`, `retryable`) is cancelled, a job given up on (`discarded`) stays so, and
  each gets the mark `meta["skipped"]` (`at`, `by`, `reason` and the `state` it had). A running or
  finished job is left as it is. Answers how many were marked.
  """
  @spec skip_jobs(Ecto.Queryable.t(), map()) :: non_neg_integer()
  def skip_jobs(query, %{skipped_at: at} = mark) do
    now = NaiveDateTime.utc_now()

    stamp =
      %{
        "at" => DateTime.to_iso8601(at),
        "by" => mark[:skipped_by_id],
        "reason" => mark[:skip_reason]
      }

    states = ["discarded" | @open_job_states]

    update =
      from(j in query,
        where: j.state in ^states,
        update: [
          set: [
            state:
              fragment(
                "CASE WHEN ?::text = ANY(?::text[]) THEN 'cancelled' ELSE ? END",
                j.state,
                ^@open_job_states,
                j.state
              ),
            cancelled_at:
              fragment(
                "CASE WHEN ?::text = ANY(?::text[]) THEN ?::timestamp ELSE ? END",
                j.state,
                ^@open_job_states,
                ^now,
                j.cancelled_at
              ),
            meta:
              fragment(
                "coalesce(?, '{}'::jsonb) || jsonb_build_object('skipped', ?::jsonb || jsonb_build_object('state', ?))",
                j.meta,
                ^stamp,
                j.state
              )
          ]
        ]
      )

    {count, _rows} = Oban.Repo.update_all(Oban.config(), update, [])
    count
  end

  @doc """
  Brings back the skipped jobs of `query`: the mark is taken off, and a job the skip cancelled is a
  job given up on (`discarded`), so it counts as failed again and is not run by itself. Answers how
  many were brought back.
  """
  @spec bring_back_jobs(Ecto.Queryable.t()) :: non_neg_integer()
  def bring_back_jobs(query) do
    now = NaiveDateTime.utc_now()

    update =
      from(j in query,
        where: fragment("? \\? 'skipped'", j.meta),
        update: [
          set: [
            state:
              fragment(
                "CASE WHEN ?::text = 'cancelled' THEN 'discarded' ELSE ? END",
                j.state,
                j.state
              ),
            cancelled_at:
              fragment(
                "CASE WHEN ?::text = 'cancelled' THEN NULL ELSE ? END",
                j.state,
                j.cancelled_at
              ),
            discarded_at:
              fragment(
                "CASE WHEN ?::text = 'cancelled' THEN ?::timestamp ELSE ? END",
                j.state,
                ^now,
                j.discarded_at
              ),
            meta: fragment("? - 'skipped'", j.meta)
          ]
        ]
      )

    {count, _rows} = Oban.Repo.update_all(Oban.config(), update, [])
    count
  end

  @doc "Leaves out of an `Oban.Job` query the jobs that were skipped."
  @spec not_skipped(Ecto.Queryable.t()) :: Ecto.Query.t()
  def not_skipped(query),
    do: where(query, [j], not fragment("coalesce(?, '{}'::jsonb) \\? 'skipped'", j.meta))

  @doc "Whether a job (or its `meta`) carries the skip mark."
  @spec skipped_job?(map()) :: boolean()
  def skipped_job?(%{meta: %{"skipped" => %{}}}), do: true
  def skipped_job?(_job), do: false

  @doc """
  Tells the rest of the CMS that an item was skipped or brought back; see the moduledoc. Always
  answers `:ok`: a notification or a plugin that fails is logged, never the skip's failure.
  """
  @spec changed(change()) :: :ok
  def changed(%{source: source, id: id, skipped?: skipped?} = change) do
    site_id = change[:site_id]

    if skipped?, do: clean_notifications(key(source, id))

    MishkaCmsCore.Layouts.SidebarStatus.changed(site_id)
    MishkaCmsCore.Layouts.TopbarNeeds.changed(site_id)

    payload = %{
      source: source,
      id: id,
      site_id: site_id,
      skipped?: skipped?,
      reason: change[:reason],
      actor_id: change[:actor_id]
    }

    MishkaInstaller.Event.Hook.call(@event, payload)

    :telemetry.execute([:mishka_cms, :skip, :changed], %{count: 1}, Map.delete(payload, :reason))
    :ok
  end

  # The unread notifications about the item, every recipient's, marked read: each one's own
  # `notification:<user>:updated` broadcast counts its bell again.
  defp clean_notifications(key) do
    MishkaCmsCore.Notify.Notification
    |> Ash.Query.filter(is_nil(read_at) and fragment("(?->>'failure') = ?", metadata, ^key))
    |> Ash.bulk_update(:mark_read, %{},
      authorize?: false,
      strategy: [:stream],
      notify?: true,
      return_errors?: true
    )
    |> case do
      %Ash.BulkResult{status: :error, errors: errors} ->
        Logger.warning("The notifications of #{key} were not cleaned: #{inspect(errors)}")

      _done ->
        :ok
    end
  end

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_none), do: nil
end
