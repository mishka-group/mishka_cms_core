# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.DoctorChecks do
  @moduledoc """
  The checks an extension adds to its "check and repair" window
  (`MishkaCmsCoreWeb.Live.Admin.Components.ExtensionInstallerPanel.doctor_modal/1`), on the
  `"doctor:checks"` mishka_installer event. The window draws them under the extension's name, with
  the look of the core's own standings, through
  `MishkaCmsCoreWeb.Live.Admin.Components.DoctorChecks`.

  ## What a plugin is handed

      %{
        app: :my_shop,      # the extension whose window is open: answer for your own app
        site_id: site_id,   # the site the window is about
        actor: user,        # the admin who opened it, with :permissions loaded
        checks: []
      }

  It answers `{:reply, %{data | checks: checks ++ mine}}`. Each window asks with its own `app`, so a
  plugin answers only when `app` is its own (or adds a check to every extension's window on
  purpose, a payment library for instance).

  ## A check

      %{
        id: "prices",                          # unique within its group
        label: "Prices the provider does not have",
        permission: "admin:dashboard:my_shop:product",   # one name or a list, ANY is enough
        group: "My shop",                      # the extension's name, already translated
        group_id: "my_shop",                   # optional, stable; `group` by default
        run: fn site_id, actor -> :ok | {:problems, [problem]} end,
        repair: %{                             # optional
          label: "Check every price at the provider",
          run: fn site_id, actor, problem_or_nil -> {:ok, text} | {:error, text} end
        }
      }

  A problem is `%{id: "price-1", text: "Pro plan, monthly: the provider does not have it."}`, with
  `repair: "Make it again"` when the check's repair can fix that problem alone: the window then
  draws that button beside it and calls the repair with the problem. The check's own repair
  button, named by `repair.label`, is drawn on the check whether it found problems or not, and is
  called with `nil`: it repairs everything the check covers, a deeper look the check itself is
  too cheap to make.

  A check without an `id`, a `label`, a `permission` or a `run` of two arguments is dropped, so a
  check is never shown to everyone by mistake. A `repair` without a `label` and a `run` of three
  arguments is dropped from its check.

  ## A repair that takes longer than the window

  A repair that cannot finish within the limit (one call to a provider for each of a thousand
  records) starts its work in the background, a job of its own, and answers
  `{:started, "Checking 71 prices. The result shows here when it is done."}` at once. The window
  shows that sentence and keeps the check's buttons busy while it listens, for up to
  `follow_timeout/0`, on `topic/1` of the site; the job tells it how far it got with `progress/3`
  and that it is done with `finished/3`, whose sentence the window shows before it runs the check
  again. The key the job names is the check's `key/2`. A window opened later sees the job's result
  on "Check again".

  ## Who sees what

  Only an actor holding the check's `permission` (`MishkaCmsCore.Settings.permitted?/2`) is shown
  it or may run its repair; the repair asks again when it is pressed. The window itself is behind
  the dashboard's own permission (`doctor_modal/1`'s `allowed?`).

  ## A slow or broken plugin

  The plugins are asked, every check runs and every repair runs in a task of its own, unlinked
  from the window, within `timeout/0` (`config :mishka_cms_core, :doctor_check_timeout`, 5 seconds
  by default). A plugin that raises, exits or takes longer answers for itself only: its check reads
  "did not answer in time" or "stopped with an error", the reason goes to the log, and every other
  check and the window carry on.

  ## Telemetry

    * `[:mishka_cms, :doctor_checks, :run]`, once for each check run: measurements `%{duration:
      native}`, metadata `%{app:, site_id:, check:, outcome: :ok | :problems | :timeout | :crashed}`;
    * `[:mishka_cms, :doctor_checks, :repair]`, once for each repair: the same, with `outcome: :ok |
      :started | :error | :timeout | :crashed | :refused`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Settings

  require Logger

  @event "doctor:checks"
  @default_timeout 5_000
  @default_follow 600_000
  @supervisor MishkaCmsCore.Runtime.TaskSupervisor

  @type problem :: %{
          required(:id) => String.t(),
          required(:text) => String.t(),
          required(:repair) => String.t() | nil
        }

  @type repair :: %{label: String.t(), run: (String.t(), map(), problem() | nil -> term())}

  @type check :: %{
          required(:key) => String.t(),
          required(:id) => String.t(),
          required(:app) => atom(),
          required(:label) => String.t(),
          required(:permission) => String.t() | [String.t()],
          required(:group) => String.t(),
          required(:group_id) => String.t(),
          required(:run) => (String.t(), map() -> term()),
          required(:repair) => repair() | nil
        }

  @type outcome :: :ok | {:problems, [problem()]} | {:error, :timeout | :crashed}

  @type result :: %{check: check(), outcome: outcome()}

  @type group :: %{id: String.t(), label: String.t(), results: [result()]}

  @doc "The mishka_installer event extensions add their checks on."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The key of the check `id` of the group `group_id`, as the window and `finished/3` name it."
  @spec key(String.t(), String.t()) :: String.t()
  def key(group_id, id) when is_binary(group_id) and is_binary(id), do: group_id <> ":" <> id

  @doc """
  The `MishkaCmsCore.PubSub` topic of `site_id`'s checks, on which a repair's background work says
  how far it got (`progress/3`) and that it is done (`finished/3`).
  """
  @spec topic(String.t()) :: String.t()
  def topic(site_id) when is_binary(site_id), do: "doctor:checks:" <> site_id

  @doc "Tells an open window how far the background repair of the check `key` on `site_id` got."
  @spec progress(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def progress(site_id, key, sentence) when is_binary(sentence),
    do: broadcast(site_id, key, {:progress, sentence})

  @doc """
  Tells an open window that the background repair of the check `key` on `site_id` is done, with
  `{:ok, sentence}` or `{:error, sentence}`; the window shows it and runs the check again.
  """
  @spec finished(String.t(), String.t(), {:ok | :error, String.t()}) :: :ok | {:error, term()}
  def finished(site_id, key, {kind, sentence} = note)
      when kind in [:ok, :error] and is_binary(sentence),
      do: broadcast(site_id, key, {:finished, note})

  @doc """
  How long, in milliseconds, a window listens for the background repair it started:
  `config :mishka_cms_core, :doctor_follow_timeout`, ten minutes by default.
  """
  @spec follow_timeout() :: non_neg_integer()
  def follow_timeout,
    do: Application.get_env(:mishka_cms_core, :doctor_follow_timeout, @default_follow)

  defp broadcast(site_id, key, message),
    do:
      Phoenix.PubSub.broadcast(
        MishkaCmsCore.PubSub,
        topic(site_id),
        {:doctor_check, key, message}
      )

  @doc """
  The limit, in milliseconds, of asking the plugins, of one check and of one repair:
  `config :mishka_cms_core, :doctor_check_timeout`, 5 000 by default.
  """
  @spec timeout() :: non_neg_integer()
  def timeout, do: Application.get_env(:mishka_cms_core, :doctor_check_timeout, @default_timeout)

  @doc """
  The checks the plugins answer for the window of `app` on `site_id`, each one `actor` may see, in
  the order they were added. `{:error, :timeout}` when the plugins did not answer within
  `opts[:timeout]` (`timeout/0`); a plugin that raises leaves the checks the others added.
  """
  @spec collect(atom(), String.t(), map(), keyword()) :: {:ok, [check()]} | {:error, :timeout}
  def collect(app, site_id, actor, opts \\ []) do
    payload = %{app: app, site_id: site_id, actor: actor, checks: []}

    case isolated(fn -> MishkaInstaller.Event.Hook.call(@event, payload) end, limit(opts)) do
      {:ok, %{checks: checks}} when is_list(checks) ->
        checks =
          checks
          |> Enum.flat_map(&check(&1, app))
          |> Enum.filter(&Settings.permitted?(&1, actor))
          |> Enum.uniq_by(& &1.key)

        {:ok, checks}

      {:ok, _not_an_answer} ->
        {:ok, []}

      {:error, reason} ->
        Logger.warning("[DoctorChecks] the plugins of #{inspect(app)} did not answer: #{reason}")
        {:error, :timeout}
    end
  end

  @doc """
  Runs every check of `checks` on `site_id` as `actor`, at once, each within `opts[:timeout]`;
  answers each check with its outcome, in the order given.
  """
  @spec run([check()], String.t(), map(), keyword()) :: [result()]
  def run(checks, site_id, actor, opts \\ []) do
    timeout = limit(opts)

    work =
      MishkaGervaz.Messages.in_caller_locale(fn check ->
        {check, timed(fn -> check.run.(site_id, actor) end)}
      end)

    @supervisor
    |> Task.Supervisor.async_stream_nolink(checks, work,
      max_concurrency: 4,
      ordered: true,
      timeout: timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, {check, {answer, took}}} ->
        %{check: check, outcome: outcome(check, site_id, answer, took)}

      {:exit, {check, reason}} ->
        %{check: check, outcome: failed(check, site_id, :run, reason, timeout)}
    end)
  end

  @doc "Runs one check again, as `run/4` does."
  @spec run_one(check(), String.t(), map(), keyword()) :: outcome()
  def run_one(check, site_id, actor, opts \\ []) do
    [%{outcome: outcome}] = run([check], site_id, actor, opts)
    outcome
  end

  @doc """
  Runs `check`'s repair on `site_id` as `actor` for `problem` (`nil` for the check's own repair),
  within `opts[:timeout]`: `{:ok, sentence}` (the sentence may be `nil`), `{:started, sentence}` for
  work it started in the background (see "A repair that takes longer than the window") or
  `{:error, sentence}`, every sentence plain words for the admin. An actor without the check's permission, or a check with
  no repair, is refused before anything runs.
  """
  @spec repair(check(), String.t(), map(), problem() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:started, String.t()} | {:error, String.t()}
  def repair(check, site_id, actor, problem, opts \\ [])

  def repair(%{repair: %{run: run}} = check, site_id, actor, problem, opts) do
    case Settings.permitted?(check, actor) do
      true ->
        run_repair(check, site_id, fn -> run.(site_id, actor, problem) end, limit(opts))

      false ->
        emit(:repair, check, site_id, :refused, 0)
        {:error, gettext("You are not allowed to run this repair.")}
    end
  end

  def repair(_check, _site_id, _actor, _problem, _opts),
    do: {:error, gettext("This check has nothing to repair.")}

  @doc """
  The results of `run/4` under their groups, in the order of each group's first check, each group
  with its `id`, `label` and `results`.
  """
  @spec groups([result()]) :: [group()]
  def groups(results) do
    by_group = Enum.group_by(results, & &1.check.group_id)

    for id <- results |> Enum.map(& &1.check.group_id) |> Enum.uniq(),
        [first | _rest] = in_group = Map.fetch!(by_group, id),
        do: %{id: id, label: first.check.group, results: in_group}
  end

  defp run_repair(check, site_id, work, limit) do
    fun = MishkaGervaz.Messages.in_caller_locale(work)

    case isolated(fn -> timed(fun) end, limit) do
      {:ok, {answer, took}} -> repaired(check, site_id, answer, took)
      {:error, reason} -> failed(check, site_id, :repair, reason, limit)
    end
  end

  # The work of a plugin, unlinked from the caller and killed at the limit: a raise, an exit or a
  # throw is its own `{:error, _}`.
  defp isolated(fun, timeout) do
    task = Task.Supervisor.async_nolink(@supervisor, fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} -> {:ok, answer}
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  # What `fun` answered and how long it took, in native units.
  defp timed(fun) do
    started = System.monotonic_time()
    answer = fun.()
    {answer, System.monotonic_time() - started}
  end

  defp outcome(check, site_id, :ok, took), do: emitted(:run, check, site_id, :ok, took, :ok)

  defp outcome(check, site_id, {:problems, problems}, took) when is_list(problems) do
    case Enum.flat_map(Enum.with_index(problems), &problem/1) do
      [] -> emitted(:run, check, site_id, :ok, took, :ok)
      found -> emitted(:run, check, site_id, :problems, took, {:problems, found})
    end
  end

  defp outcome(check, site_id, other, took) do
    Logger.warning("[DoctorChecks] the check #{check.key} answered #{inspect(other)}")
    emitted(:run, check, site_id, :crashed, took, {:error, :crashed})
  end

  defp repaired(check, site_id, {:ok, sentence}, took)
       when is_binary(sentence) or is_nil(sentence),
       do: emitted(:repair, check, site_id, :ok, took, {:ok, sentence})

  defp repaired(check, site_id, {:started, sentence}, took) when is_binary(sentence),
    do: emitted(:repair, check, site_id, :started, took, {:started, sentence})

  defp repaired(check, site_id, :ok, took),
    do: emitted(:repair, check, site_id, :ok, took, {:ok, nil})

  defp repaired(check, site_id, {:error, sentence}, took) when is_binary(sentence),
    do: emitted(:repair, check, site_id, :error, took, {:error, sentence})

  defp repaired(check, site_id, other, took) do
    Logger.warning("[DoctorChecks] the repair of #{check.key} answered #{inspect(other)}")
    emitted(:repair, check, site_id, :crashed, took, {:error, broken_words()})
  end

  defp failed(check, site_id, kind, :timeout, limit) do
    Logger.warning("[DoctorChecks] the #{kind} of #{check.key} took longer than its limit")
    answer = if kind == :run, do: {:error, :timeout}, else: {:error, slow_words()}
    emitted(kind, check, site_id, :timeout, native(limit), answer)
  end

  defp failed(check, site_id, kind, reason, _limit) do
    Logger.warning("[DoctorChecks] the #{kind} of #{check.key} stopped: #{inspect(reason)}")
    answer = if kind == :run, do: {:error, :crashed}, else: {:error, broken_words()}
    emitted(kind, check, site_id, :crashed, 0, answer)
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp emitted(kind, check, site_id, outcome, took, answer) do
    emit(kind, check, site_id, outcome, took)
    answer
  end

  defp emit(kind, check, site_id, outcome, duration) do
    :telemetry.execute(
      [:mishka_cms, :doctor_checks, kind],
      %{duration: duration},
      %{app: check.app, site_id: site_id, check: check.key, outcome: outcome}
    )
  end

  defp slow_words, do: gettext("The repair did not answer in time. Try it again in a moment.")
  defp broken_words, do: gettext("The repair stopped with an error. The server log has why.")

  defp check(%{id: id, label: label, permission: permission, run: run} = check, app)
       when is_binary(id) and id != "" and is_binary(label) and label != "" and
              is_function(run, 2) and permission not in [nil, "", []] do
    group = text(check[:group]) || to_string(app)
    group_id = text(check[:group_id]) || group

    [
      %{
        key: key(group_id, id),
        id: id,
        app: app,
        label: label,
        permission: permission,
        group: group,
        group_id: group_id,
        run: run,
        repair: repair_of(check[:repair])
      }
    ]
  end

  defp check(_other, _app), do: []

  defp repair_of(%{label: label, run: run})
       when is_binary(label) and label != "" and is_function(run, 3),
       do: %{label: label, run: run}

  defp repair_of(_none), do: nil

  defp problem({%{text: text} = problem, index}) when is_binary(text) and text != "" do
    [
      %{
        id: text(problem[:id]) || Integer.to_string(index),
        text: text,
        repair: text(problem[:repair])
      }
    ]
  end

  defp problem(_other), do: []

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_none), do: nil

  defp limit(opts), do: Keyword.get_lazy(opts, :timeout, &timeout/0)
end
