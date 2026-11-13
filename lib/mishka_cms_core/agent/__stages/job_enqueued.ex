# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.JobEnqueued do
  @moduledoc """
  The operation left an Oban job waiting.

      {:job_enqueued, :feed_job, worker: MyExtension.Workers.Feed, args: &MyExtension.Agent.Checks.feed_args/1}

  `sitemap/1` is the declaration of the site's sitemap job, which every write that changes what a
  sitemap lists leaves behind (`MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh`).

  ## Options

    * `:worker` — required: the worker module.
    * `:args` — what the job's args must contain (a JSON containment, `@>`), as a map with string
      keys or a check that returns one from the context. Nothing by default.
    * `:states` — the job states that count, by default every state but `discarded` and
      `cancelled`.
    * `:skip_when` — a check that answers a reason (an atom) when the job is not expected, such as
      jobs being off in a test run, or `nil` when it is.

  ## How it reads

  One indexed query on `oban_jobs` through Oban's repo, newest first, limit 1. `Oban.insert/1`
  answering `{:ok, job}` is not taken as evidence: the row is read back. A job whose
  `meta["receipt_id"]` is this receipt's is `correlated: :receipt`; another matching job, such as a
  unique job this operation's enqueue was folded into, is `correlated: :coalesced`.

  ## What verified means

  Right after the operation, a matching job was in the table in a state that will run or has run.

  ## What it does not prove

  That the job will succeed (that is `:job_done`), or, for a coalesced job, which operation queued
  it. Under `config :mishka_cms_core, env_test?: true` the runtime jobs are not enqueued at all, and
  `sitemap/1` skips (`:off`) rather than claims a job.
  """
  @behaviour MishkaCmsCore.Agent.Stages

  import Ecto.Query, only: [from: 2]

  alias MishkaCmsCore.Agent.Stages
  alias MishkaCmsCore.Runtime.States.SiteState

  @states ~w(available scheduled executing retryable completed)

  @impl true
  def layer(_opts), do: :db

  @impl true
  def key(opts), do: opts |> Keyword.fetch!(:worker) |> inspect()

  @impl true
  def verify(ctx, opts) do
    case skip(ctx, opts) do
      nil -> read(ctx, opts)
      reason -> {:skip, reason}
    end
  end

  @doc false
  def skip(ctx, opts) do
    case Keyword.get(opts, :skip_when) do
      nil -> nil
      check -> Stages.call(check, ctx)
    end
  end

  @doc """
  The site's sitemap job, as an operation declares it:

      stages: [..., MishkaCmsCore.Agent.Stages.JobEnqueued.sitemap(), ...]

  Skipped (`:off`) in a test run and (`:not_applicable`) for a global record or a site that is
  switched off, where `MishkaCmsCore.Runtime.Compilers.SitemapCompiler.schedule/1` enqueues nothing
  for the site.
  """
  @spec sitemap(atom()) :: {:job_enqueued, atom(), keyword()}
  def sitemap(name \\ :sitemap_job) do
    {:job_enqueued, name,
     worker: MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker,
     args: &__MODULE__.sitemap_args/1,
     states: ~w(available scheduled),
     skip_when: &__MODULE__.sitemap_off/1}
  end

  @doc false
  def sitemap_args(%{site_id: site_id}),
    do: %{"data" => %{"site_id" => site_id, "type" => "sitemap"}}

  @doc false
  def sitemap_off(%{site_id: site_id}) do
    cond do
      Application.get_env(:mishka_cms_core, :env_test?, false) -> :off
      not is_binary(site_id) -> :not_applicable
      not match?({:ok, %{active: true}}, SiteState.get(site_id)) -> :not_applicable
      true -> nil
    end
  end

  defp read(ctx, opts) do
    worker = key(opts)
    states = Keyword.get(opts, :states, @states)
    args = args(ctx, opts)

    query =
      from(job in Oban.Job,
        where: job.worker == ^worker and job.state in ^states,
        where: fragment("? @> ?", job.args, ^args),
        order_by: [desc: job.id],
        limit: 1,
        select: {job.state, job.meta}
      )

    case Oban.Repo.one(Oban.config(), query) do
      {state, meta} -> {:ok, %{state: state, worker: worker, correlated: correlated(meta, ctx)}}
      nil -> {:error, :not_found, %{worker: worker}}
    end
  end

  defp args(ctx, opts) do
    case Keyword.get(opts, :args, %{}) do
      args when is_map(args) -> args
      check -> Stages.call(check, ctx)
    end
  end

  defp correlated(%{"receipt_id" => id}, %{id: id}), do: :receipt
  defp correlated(_meta, _ctx), do: :coalesced
end
