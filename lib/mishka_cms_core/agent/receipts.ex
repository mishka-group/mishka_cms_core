# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Receipts do
  @moduledoc """
  Receipts: structured evidence of what an operation actually did, for an agent (or an admin, or a
  test) that must not take "it worked" on trust.

  An operation runs through `run/3` (an Ash action) or `track/3` (anything else). Each one gets a
  correlation id and a `MishkaCmsCore.Agent.Receipt` that lists the stages its declaration
  (`MishkaCmsCore.Agent.Operation`) names, each checked by its own kind's module
  (`MishkaCmsCore.Agent.Stages`) from independent evidence: a separate read of the row, the Oban
  table, a PubSub listener, a LiveView that saw the broadcast. A stage is verified only by its
  check, never by the caller, and a stage that could not be checked says why. The guide
  `guides/agent-receipts.md` walks through it.

      {:ok, post, receipt} =
        post
        |> Ash.Changeset.for_update(:publish, %{}, actor: admin, tenant: site.id)
        |> Receipts.run("blog:blog_post:publish", source: :agent)

      receipt.status
      #=> :verified

  ## Off unless it is asked for

  The `agent.receipts` setting (General, master only, off by default) turns receipts on for the
  node. It is kept in `:persistent_term`, so with it off `run/3` is the Ash action and `track/3`
  is the function, plus one read of it: no table, no query, no subscription, and the receipt is
  `nil`.

  ## Never in the way

  A receipt never changes what the operation returns or raises. A check that raises is a failed
  stage. A fault in the receipts themselves is logged and the operation's result is returned with
  no receipt.

  ## The correlation id

  While an operation runs its id is the process's current receipt (`current/0`) and the Logger's
  `receipt_id` metadata, and it travels:

    * into the Ash action's shared context (`context.shared.receipt_id`), so it reaches every
      notifier, nested actions and the broadcast payload;
    * into an Oban job's `meta` built with `job_meta/1` (the core's runtime, sitemap and share-card jobs are);
    * into another process only through `carry/1`.

  ## Reading

  `get/3` and `recent/2` answer only what the viewer may read, and a receipt the viewer may not
  read is `{:error, :not_found}`, exactly as one that does not exist. `MishkaCmsCore.Agent.Receipt.to_public/1`
  turns one into a JSON-safe map. These are the functions an API or an MCP tool calls with its
  session's user.

  ## Bounds and cost

  Kept in memory on the node that ran the operation, bounded (`MishkaCmsCore.Agent.ReceiptStore`).
  With receipts on, an operation costs what its declared stages read: one primary-key query for a
  `:db_read_back`, one indexed query for a `:job_enqueued`, a subscription for a
  `:broadcast_published`. Reading receipts never touches the database.

  ## Announcing a finished receipt

  Another extension saves, shows or alerts on receipts through the `agent:receipt:finished` event
  (`finished_event/0`), without the core knowing it. A plugin gets

      %{receipt: Receipt.to_public(receipt), site_id: site_id, operation: name,
        trigger: :finished, node: node()}

  when the receipt is stored with its status, and the same with `trigger: :late`, the receipt read
  again, each time late evidence (`:job_done`, `:ui_observed`) is kept for it. `node` is the node
  that announced it: the one that ran the operation and heard the late evidence. The receipt is the
  redacted, JSON-safe map, never the record, the params or the changeset. Its `"id"` is the key: a
  later call carries newer evidence for the same receipt.

  Plugins run in a task under `MishkaCmsCore.Runtime.TaskSupervisor`, after the operation has
  returned its result, so they never slow it down or change it, and a plugin that raises is logged
  and nothing else. With receipts off, or no plugin on the event, nothing is started: the check is
  one `:persistent_term` read. Announcing makes no query.

  ## Telemetry

    * `[:mishka_cms, :agent, :receipt, :stop]` — a receipt was stored. Measurements `elapsed_us`
      and `stage_count`; metadata `id`, `operation`, `status`, `site_id`.
    * `[:mishka_cms, :agent, :receipt, :stage]` — once per stage of a stored receipt. Measurements
      `elapsed_us`; metadata `id`, `operation`, `site_id`, `kind`, `name`, `layer`, `status`,
      `reason`.
    * `[:mishka_cms, :agent, :receipt, :late]` — late evidence was kept for a receipt this node
      knows. Measurements `system_time`; metadata `id`, `kind`, `name`, `layer`, `status`,
      `reason`.

  They carry ids, names and statuses only, and are emitted in the process that ran the operation
  (or heard the late evidence), as `:telemetry` handlers are.
  """

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Activity.Helpers
  alias MishkaCmsCore.Agent.{Operation, Receipt, ReceiptStore, Redactor, Stages}
  alias MishkaCmsCore.Agent.Receipt.Stage
  alias MishkaInstaller.Event.{Hook, ModuleStateCompiler}

  require Logger

  @switch {__MODULE__, :on}
  @current {__MODULE__, :current}
  @setting "agent.receipts"
  @before_action [:dispatched, :validated]
  @undeclared [:dispatched, :validated, :action_committed]
  @max_limit 100
  @default_limit 20
  @telemetry [:mishka_cms, :agent, :receipt, :stop]
  @telemetry_stage [:mishka_cms, :agent, :receipt, :stage]
  @telemetry_late [:mishka_cms, :agent, :receipt, :late]
  @finished_event "agent:receipt:finished"

  @typedoc "Who reads: a user, as the rest of the core passes one."
  @type viewer :: map() | nil

  @doc "Whether receipts are kept on this node: the `agent.receipts` setting."
  @spec on?() :: boolean()
  def on?, do: :persistent_term.get(@switch, false)

  @doc false
  # Reads the setting from the settings cache again and keeps it for `on?/0`.
  @spec switch_changed() :: boolean()
  def switch_changed do
    switch(MishkaCmsCore.Settings.get(@setting, false) == true)
  rescue
    ArgumentError -> false
  end

  @doc false
  # Turns receipts on or off on this node, as the setting does.
  @spec switch(boolean()) :: boolean()
  def switch(on) when is_boolean(on) do
    if on?() != on, do: :persistent_term.put(@switch, on)
    on
  end

  @doc "The event a finished receipt is announced on, as the moduledoc describes."
  @spec finished_event() :: String.t()
  def finished_event, do: @finished_event

  @doc "The setting that turns receipts on."
  @spec setting() :: String.t()
  def setting, do: @setting

  @doc """
  Runs the Ash action of `changeset` as `operation` (a name, or an `Operation` built in place) and
  returns its result with the receipt: `{:ok, record, receipt}` or `{:error, error, receipt}`.

  `opts` are `Ash.create/2`, `Ash.update/2` or `Ash.destroy/2`'s (`:actor`, `:tenant`,
  `:authorize?` ...), plus:

    * `:source` — who asks, one of `MishkaCmsCore.Agent.Receipt.sources/0`; `:system` by default.
    * `:meta` — scalars kept on the receipt (redacted, see `MishkaCmsCore.Agent.Redactor`).

  A destroy returns the destroyed record. With receipts off the receipt is `nil`.
  """
  @spec run(String.t() | Operation.t(), Ash.Changeset.t(), keyword()) ::
          {:ok, term(), Receipt.t() | nil} | {:error, term(), Receipt.t() | nil}
  def run(operation, %Ash.Changeset{} = changeset, opts \\ []) do
    {receipt_opts, ash_opts} = Keyword.split(opts, [:source, :meta])

    base = %{
      resource: changeset.resource,
      action: changeset.action && changeset.action.name,
      action_type: changeset.action_type,
      changeset: changeset,
      subject_id: Redactor.id(Map.get(changeset.data, :id)),
      site_id: site_of(changeset),
      actor: Keyword.get(ash_opts, :actor) || get_in(changeset.context, [:private, :actor]),
      params: nil
    }

    {result, receipt} =
      tracked(operation, base, receipt_opts, fn ctx ->
        changeset
        |> carry_id(ctx)
        |> execute(ash_opts)
      end)

    case result do
      {:ok, record} -> {:ok, record, receipt}
      {:error, error} -> {:error, error, receipt}
    end
  end

  @doc """
  Runs `fun` as `operation` and returns `{fun's result, receipt}`.

  `fun` gets the receipt id (`nil` with receipts off). Its result is read as the
  `:action_committed` evidence: `:ok` or `{:ok, value}` is success, `:error` or `{:error, reason}`
  a refusal. Inside it, `stage/2` adds evidence only the caller can gather.

  `opts`:

    * `:actor`, `:site_id`, `:subject_id` — who acts, on which site and on what.
    * `:resource`, `:action` — when `fun` runs an Ash action of its own.
    * `:params` — what the declared checks need to know (an app name, a version), passed to them
      in the context and never stored.
    * `:source`, `:meta` — as `run/3`'s.
  """
  @spec track(String.t() | Operation.t(), keyword(), (String.t() | nil -> result)) ::
          {result, Receipt.t() | nil}
        when result: term()
  def track(operation, opts \\ [], fun) when is_function(fun, 1) do
    base = %{
      resource: Keyword.get(opts, :resource),
      action: Keyword.get(opts, :action),
      action_type: nil,
      changeset: nil,
      subject_id: Redactor.id(Keyword.get(opts, :subject_id)),
      site_id: Keyword.get(opts, :site_id),
      actor: Keyword.get(opts, :actor),
      params: Keyword.get(opts, :params)
    }

    tracked(operation, base, Keyword.take(opts, [:source, :meta]), &fun.(&1 && &1.id))
  end

  @doc """
  Inside `track/3` or `run/3`, records the stage `name` from the evidence `fun` gathers (an answer
  as `MishkaCmsCore.Agent.Receipt.Stage.new/3` reads it). A declared stage of that name takes this
  evidence instead of its own check; any other is kept as a `:side_effect` on the `:app` layer.
  Outside an operation, or with receipts off, it does nothing.
  """
  @spec stage(atom(), (-> Stages.answer())) :: :ok
  def stage(name, fun) when is_atom(name) and is_function(fun, 0) do
    with id when is_binary(id) <- current(),
         %{specs: specs, manual: manual} = flight <- Process.get({__MODULE__, id}) do
      spec =
        Enum.find(specs, &(&1.name == name)) ||
          %{kind: :side_effect, name: name, layer: :app, key: nil, module: Stages.SideEffect}

      started = System.monotonic_time(:microsecond)
      stage = Stage.new(spec, answered(fun), System.monotonic_time(:microsecond) - started)
      Process.put({__MODULE__, id}, %{flight | manual: Map.put(manual, name, stage)})
    end

    :ok
  end

  defp answered(fun) do
    fun.()
  catch
    kind, reason ->
      {:error, :raised, %{error: Redactor.error(kind, reason, __STACKTRACE__).module}}
  end

  @doc "The receipt id of the operation running in this process, or `nil`."
  @spec current() :: String.t() | nil
  def current, do: Process.get(@current)

  @doc """
  `meta` for an Oban job built while an operation runs, with the receipt id under `"receipt_id"`,
  so the job's result reaches the receipt (`MishkaCmsCore.Agent.Stages.JobDone`). Unchanged outside
  an operation.

      MyWorker.new(args, meta: Receipts.job_meta(%{slug: slug}))
  """
  @spec job_meta(map()) :: map()
  def job_meta(meta \\ %{}) do
    case current() do
      nil -> meta
      id -> Map.put(meta, "receipt_id", id)
    end
  end

  @doc """
  `fun` wrapped to run with this process's current receipt, for work handed to another process:

      Task.async(Receipts.carry(fn -> Oban.insert(job) end))
  """
  @spec carry((-> result)) :: (-> result) when result: term()
  def carry(fun) when is_function(fun, 0) do
    case current() do
      nil -> fun
      id -> fn -> within(id, fun) end
    end
  end

  defp within(id, fun) do
    previous = enter(id)

    try do
      fun.()
    after
      leave(previous)
    end
  end

  @doc """
  The receipt `id` if `viewer` may read it, `{:error, :not_found}` otherwise.

  A viewer reads a receipt when it holds `admin:<surface>:agent:receipts` (a full admin of the
  surface does), the receipt's site is in its reach (a master reads every site, a site user its
  own, `MishkaCmsCore.Activity.Helpers.reach/1`), and it holds one of the operation's `visibility`
  names, or is a full admin of the surface.

  `opts`: `surface: :dashboard | :api` (`:dashboard` by default), the surface the viewer asks
  from, as `MishkaCmsCore.Accounts.Checks.AccessPermissions` reads permission names.
  """
  @spec get(String.t(), viewer(), keyword()) :: {:ok, Receipt.t()} | {:error, :not_found}
  def get(id, viewer, opts \\ []) do
    with %{} = reader <- reader(viewer, opts),
         %Receipt{} = receipt <- ReceiptStore.fetch(id),
         true <- readable?(reader, receipt) do
      {:ok, receipt}
    else
      _unreadable -> {:error, :not_found}
    end
  end

  @doc """
  The newest receipts `viewer` may read (see `get/3`), newest first.

  `opts`: `:surface` as `get/3`'s; `:limit` (#{@default_limit} by default, at most #{@max_limit}); and
  filters, each narrowing and never widening what the viewer may read: `:site_id`, `:operation`,
  `:actor_id`, `:subject_id`, `:status` and `:since` (a `DateTime`).
  """
  @spec recent(viewer(), keyword()) :: [Receipt.t()]
  def recent(viewer, opts \\ []) do
    case reader(viewer, opts) do
      nil ->
        []

      reader ->
        limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)
        ReceiptStore.newest(&(readable?(reader, &1) and wanted?(&1, opts)), limit)
    end
  end

  @doc "How many receipts this node keeps, how many were dropped, and the bounds. No receipt data."
  @spec stats() :: %{
          count: non_neg_integer(),
          dropped: non_neg_integer(),
          bounds: keyword(),
          on?: boolean()
        }
  def stats,
    do: %{
      count: ReceiptStore.count(),
      dropped: ReceiptStore.dropped(),
      bounds: ReceiptStore.bounds(),
      on?: on?()
    }

  @doc false
  # A stored receipt with no permission asked: for the core's own code and tests only.
  @spec get_unchecked(String.t()) :: Receipt.t() | nil
  def get_unchecked(id), do: ReceiptStore.fetch(id)

  @doc false
  # Keeps evidence that arrived after the receipt was stored, from `UiObserver` or `JobDone`, and
  # announces the receipt again.
  @spec late(String.t(), Stage.t()) :: :ok | :unknown
  def late(id, %Stage{} = stage) do
    with :ok <- ReceiptStore.late(id, stage) do
      if on?(), do: announce_late(id, stage)
      :ok
    end
  end

  defp announce_late(id, stage) do
    :telemetry.execute(
      @telemetry_late,
      %{system_time: System.system_time()},
      Map.put(stage_meta(stage), :id, id)
    )

    announce(id, :late)
  end

  ## Running

  defp tracked(operation, base, receipt_opts, work) do
    case on?() and ReceiptStore.running?() do
      false -> {work.(nil), nil}
      true -> tracked_on(operation, base, receipt_opts, work)
    end
  end

  defp tracked_on(operation, base, receipt_opts, work) do
    case prepare(operation, base, receipt_opts) do
      {:ok, ctx} ->
        previous = enter(ctx.id)

        try do
          ctx = %{ctx | armed: Stages.arm(ctx.specs, ctx)}
          early = check_all(Enum.filter(ctx.specs, &(&1.kind in @before_action)), ctx)

          result =
            try do
              work.(ctx)
            catch
              kind, reason ->
                stacktrace = __STACKTRACE__
                conclude(ctx, early, {:raised, kind, reason, stacktrace})
                :erlang.raise(kind, reason, stacktrace)
            end

          {result, conclude(ctx, early, {:returned, result})}
        after
          Process.delete({__MODULE__, ctx.id})
          leave(previous)
        end

      :error ->
        {work.(nil), nil}
    end
  end

  defp prepare(operation, base, receipt_opts) do
    {name, declaration} = resolve(operation)
    {:ok, specs} = Operation.specs(if declaration, do: declaration, else: @undeclared)
    id = Receipt.new_id()
    :ok = ReceiptStore.open(id)
    Process.put({__MODULE__, id}, %{specs: specs, manual: %{}})

    receipt = %Receipt{
      id: id,
      operation: name,
      resource: base.resource,
      action: base.action,
      subject_id: base.subject_id,
      site_id: base.site_id,
      actor: Redactor.actor(base.actor),
      source: source(Keyword.get(receipt_opts, :source)),
      required: if(declaration, do: declaration.required, else: []),
      visibility: if(declaration, do: declaration.visibility, else: []),
      started_at: DateTime.utc_now(),
      started_mono: System.monotonic_time(:microsecond),
      node: node(),
      meta: Redactor.evidence(Keyword.get(receipt_opts, :meta, %{}))
    }

    {:ok,
     Map.merge(base, %{
       id: id,
       operation: declaration,
       operation_name: name,
       specs: specs,
       receipt: receipt,
       result: nil,
       armed: %{}
     })}
  rescue
    error ->
      Logger.warning("[Agent] a receipt could not be opened: #{inspect(error.__struct__)}")
      :error
  end

  defp resolve(%Operation{name: name} = operation), do: {name, operation}
  defp resolve(name) when is_binary(name), do: {name, Operation.lookup(name)}

  defp source(source) do
    if source in Receipt.sources(), do: source, else: :system
  end

  # The work returned or raised: every stage not checked before it is checked now, unless the action
  # itself did not commit, in which case they were never reached.
  defp conclude(ctx, early, outcome) do
    ctx = after_work(ctx, outcome)
    manual = Process.get({__MODULE__, ctx.id}, %{manual: %{}}).manual

    pending =
      Enum.reject(ctx.specs, &(Map.has_key?(early, &1.name) or Map.has_key?(manual, &1.name)))

    checked =
      pending
      |> Enum.reduce_while(Map.merge(early, manual), fn spec, checked ->
        stage = Stages.check(spec, ctx)
        checked = Map.put(checked, spec.name, stage)

        case spec.kind == :action_committed and stage.status == :failed do
          true -> {:halt, checked}
          false -> {:cont, checked}
        end
      end)

    Stages.disarm(Enum.reject(ctx.specs, &Map.has_key?(checked, &1.name)), ctx.armed)
    finish(ctx, checked, manual, outcome)
  rescue
    error ->
      Logger.warning("[Agent] a receipt could not be finished: #{inspect(error.__struct__)}")
      nil
  end

  defp after_work(ctx, {:returned, result}) do
    %{
      ctx
      | result: result,
        subject_id: Redactor.id(subject_of(result)) || ctx.subject_id,
        site_id: record_site(ctx.resource, result) || ctx.site_id
    }
  end

  defp after_work(ctx, {:raised, kind, reason, _stacktrace}),
    do: %{ctx | result: {:error, %{raised: kind, reason: reason}}}

  defp finish(ctx, checked, manual, outcome) do
    declared = Enum.map(ctx.specs, &(Map.get(checked, &1.name) || Stages.not_reached(&1)))
    extra = manual |> Map.drop(Enum.map(ctx.specs, & &1.name)) |> Map.values()
    stages = declared ++ extra
    now = System.monotonic_time(:microsecond)

    receipt = %{
      ctx.receipt
      | subject_id: ctx.subject_id,
        site_id: ctx.site_id,
        stages: stages,
        status: Receipt.status(stages, ctx.receipt.required),
        finished_at: DateTime.utc_now(),
        elapsed_us: now - ctx.receipt.started_mono,
        error: error_of(outcome)
    }

    stored = ReceiptStore.put(receipt) || receipt

    :telemetry.execute(
      @telemetry,
      %{elapsed_us: receipt.elapsed_us, stage_count: length(stages)},
      %{
        operation: receipt.operation,
        status: receipt.status,
        site_id: receipt.site_id,
        id: receipt.id
      }
    )

    common = %{id: receipt.id, operation: receipt.operation, site_id: receipt.site_id}

    Enum.each(stages, fn stage ->
      :telemetry.execute(
        @telemetry_stage,
        %{elapsed_us: stage.elapsed_us || 0},
        Map.merge(stage_meta(stage), common)
      )
    end)

    announce(receipt.id, :finished)
    stored
  end

  defp stage_meta(%Stage{} = stage),
    do: %{
      kind: stage.kind,
      name: stage.name,
      layer: stage.layer,
      status: stage.status,
      reason: stage.reason
    }

  # Plugins hear the receipt from a task, read from the store then, so a receipt still running (late
  # evidence before it was stored) is announced once it is.
  defp announce(id, trigger) do
    case ModuleStateCompiler.event_module(@finished_event) do
      nil -> :ok
      _module -> start_announce(fn -> announced(id, trigger) end)
    end
  end

  defp start_announce(work) do
    case Process.whereis(MishkaCmsCore.Runtime.TaskSupervisor) do
      nil -> Task.start(work)
      _supervisor -> Task.Supervisor.start_child(MishkaCmsCore.Runtime.TaskSupervisor, work)
    end

    :ok
  end

  defp announced(id, trigger) do
    case ReceiptStore.fetch(id) do
      %Receipt{} = receipt ->
        Hook.call(
          @finished_event,
          %{
            receipt: Receipt.to_public(receipt),
            site_id: receipt.site_id,
            operation: receipt.operation,
            trigger: trigger,
            node: node()
          },
          raised: :raised
        )

      nil ->
        :ok
    end
  end

  defp error_of({:raised, kind, reason, stacktrace}), do: Redactor.error(kind, reason, stacktrace)
  defp error_of({:returned, {:error, reason}}), do: Redactor.error(:error, reason)
  defp error_of(_success), do: nil

  defp check_all(specs, ctx), do: Map.new(specs, &{&1.name, Stages.check(&1, ctx)})

  defp enter(id) do
    previous = {Process.put(@current, id), Logger.metadata()[:receipt_id]}
    Logger.metadata(receipt_id: id)
    previous
  end

  defp leave({previous_id, previous_meta}) do
    if previous_id, do: Process.put(@current, previous_id), else: Process.delete(@current)
    Logger.metadata(receipt_id: previous_meta)
  end

  ## Ash

  defp carry_id(changeset, %{id: id}),
    do: Ash.Changeset.set_context(changeset, %{shared: %{receipt_id: id}})

  defp carry_id(changeset, nil), do: changeset

  defp execute(%Ash.Changeset{action_type: :create} = changeset, opts),
    do: Ash.create(changeset, opts)

  defp execute(%Ash.Changeset{action_type: :update} = changeset, opts),
    do: Ash.update(changeset, opts)

  defp execute(%Ash.Changeset{action_type: :destroy} = changeset, opts) do
    case Ash.destroy(changeset, Keyword.put_new(opts, :return_destroyed?, true)) do
      :ok -> {:ok, nil}
      result -> result
    end
  end

  defp subject_of({:ok, %{id: id}}), do: id
  defp subject_of(_result), do: nil

  defp site_of(%Ash.Changeset{resource: resource, data: data, to_tenant: tenant}) do
    record_site(resource, {:ok, data}) || tenant_id(tenant)
  end

  defp tenant_id(tenant) when is_binary(tenant), do: tenant
  defp tenant_id(_tenant), do: nil

  defp record_site(resource, {:ok, %{} = record})
       when is_atom(resource) and not is_nil(resource) do
    with true <- Ash.Resource.Info.resource?(resource),
         attribute when is_atom(attribute) and not is_nil(attribute) <-
           Ash.Resource.Info.multitenancy_attribute(resource),
         site_id when is_binary(site_id) <- Map.get(record, attribute) do
      site_id
    else
      _none -> nil
    end
  end

  defp record_site(_resource, _result), do: nil

  ## Reading

  defp reader(viewer, opts) do
    surface = if Keyword.get(opts, :surface) == :api, do: :api, else: :dashboard
    context = if surface == :api, do: %{shared: %{admin_surface: :api}}, else: %{}
    viewer = AccessPermissions.with_permissions(viewer)

    with reach when reach != :nothing <- Helpers.reach(viewer),
         true <-
           AccessPermissions.match?(viewer, context, permissions: [read_permission(surface)]) do
      %{
        viewer: viewer,
        reach: reach,
        context: context,
        full?: AccessPermissions.match?(viewer, context, permissions: [full_permission(surface)])
      }
    else
      _nobody -> nil
    end
  end

  defp read_permission(:dashboard), do: "admin:dashboard:agent:receipts"
  defp read_permission(:api), do: "admin:api:agent:receipts"

  defp full_permission(:dashboard), do: "admin:dashboard:*"
  defp full_permission(:api), do: "admin:api:*"

  defp readable?(%{reach: reach} = reader, %Receipt{site_id: site_id, visibility: visibility}) do
    in_reach?(reach, site_id) and
      (reader.full? or
         (visibility != [] and
            AccessPermissions.match?(reader.viewer, reader.context, permissions: visibility)))
  end

  defp in_reach?(:everything, _site_id), do: true
  defp in_reach?({:site, site_id}, site_id), do: true
  defp in_reach?(_reach, _site_id), do: false

  defp wanted?(receipt, opts) do
    Enum.all?(opts, fn
      {:site_id, site_id} -> receipt.site_id == site_id
      {:operation, operation} -> receipt.operation == operation
      {:actor_id, actor_id} -> receipt.actor.id == actor_id
      {:subject_id, subject_id} -> receipt.subject_id == subject_id
      {:status, status} -> receipt.status == status
      {:since, %DateTime{} = since} -> DateTime.compare(receipt.started_at, since) != :lt
      _other -> true
    end)
  end
end
