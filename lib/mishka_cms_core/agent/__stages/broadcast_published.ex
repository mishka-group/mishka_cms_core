# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Stages.BroadcastPublished do
  @moduledoc """
  The action's PubSub broadcast left this node's PubSub.

      :broadcast_published
      {:broadcast_published, topics: &MyExtension.Agent.Checks.topics/1, event: "updated"}

  ## Options

    * `:topics` — the topics to listen on, a list or a check that returns one from the context. By
      default they are worked out from the resource's `pub_sub` block for the action, with the
      values the changeset holds before the action runs (a topic naming a value the changeset does
      not hold yet cannot be worked out, and is left out).
    * `:event` — the event to wait for; the publication's event, or the action's name, by default.
    * `:window_ms` — how long to wait for the message after the action returned, `0` by default.

  ## How it listens

  Before the action runs, a short-lived process of its own subscribes to the topics, so the
  caller's mailbox (a LiveView's, say) is never touched. Ash broadcasts from the process that ran
  the action, before the action returns, so with the default window the message is already there
  when the action returns: nothing is waited for. A message counts when its topic and event match
  and its notification carries this receipt's id (`correlated: :receipt`): a broadcast another
  operation sent on the same topic, for the same record or not, never counts. Only when the
  publication transforms the payload away from the notification is the acted-on record's id all there
  is to go by (`correlated: :record`).

  ## What verified means

  The broadcast was published on this node's PubSub.

  ## What it does not prove

  That anybody is listening, or that a LiveView did anything with it (that is `:ui_observed`).
  Inside an outer transaction Ash holds the notifications until it ends, and a broadcast sent from
  another process can arrive after the window: both leave the stage unverified (`:timeout`), never
  failed, because late is not absent. A resource with no publication for the action is skipped
  (`:no_publication`).
  """
  @behaviour MishkaCmsCore.Agent.Stages

  alias Ash.Notifier.PubSub.Info
  alias MishkaCmsCore.Agent.Redactor
  alias MishkaCmsCore.Agent.Stages

  @impl true
  def layer(_opts), do: :app

  @impl true
  def arm(ctx, opts) do
    case topics(ctx, opts) do
      [] -> :no_publication
      topics -> listen(ctx, topics, event(ctx, opts))
    end
  end

  @impl true
  def disarm({:listener, pid, _ref, monitor, _topics, _event}) do
    Process.demonitor(monitor, [:flush])
    Process.exit(pid, :kill)
    :ok
  end

  def disarm(_nothing), do: :ok

  @impl true
  def verify(%{armed: armed} = ctx, opts) do
    case Map.get(armed, ctx.stage) do
      :no_publication ->
        {:skip, :no_publication}

      {:listener, _pid, _ref, _monitor, _topics, _event} = listener ->
        collect(listener, ctx, opts)

      _not_armed ->
        {:error, :not_armed}
    end
  end

  def verify(_ctx, _opts), do: {:error, :not_armed}

  defp listen(ctx, topics, event) do
    caller = self()
    ref = make_ref()
    resource = ctx.resource

    {pid, monitor} =
      spawn_monitor(fn ->
        watch = Process.monitor(caller)
        Enum.each(topics, &subscribe(resource, &1))
        send(caller, {ref, :ready})
        wait(ref, caller, watch)
      end)

    receive do
      {^ref, :ready} -> {:listener, pid, ref, monitor, topics, event}
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :not_armed
    end
  end

  defp wait(ref, caller, watch) do
    receive do
      {^ref, :collect, window, match?} -> send(caller, {ref, :seen, drain(match?, window)})
      {:DOWN, ^watch, :process, _caller, _reason} -> :ok
    end
  end

  # Everything already in the mailbox first; then, only if nothing matched, up to `window` ms.
  defp drain(match?, window) do
    receive do
      message ->
        case match?.(message) do
          false -> drain(match?, window)
          seen -> seen
        end
    after
      0 -> wait_window(match?, window)
    end
  end

  defp wait_window(_match?, 0), do: nil

  defp wait_window(match?, window) do
    receive do
      message ->
        case match?.(message) do
          false -> wait_window(match?, window)
          seen -> seen
        end
    after
      window -> nil
    end
  end

  defp collect({:listener, pid, ref, monitor, topics, event}, ctx, opts) do
    id = ctx.id
    subject = ctx.subject_id
    match? = &matched(&1, topics, event, id, subject)
    send(pid, {ref, :collect, Keyword.get(opts, :window_ms, 0), match?})

    receive do
      {^ref, :seen, nil} ->
        Process.demonitor(monitor, [:flush])
        {:unverified, :timeout, %{event: event}}

      {^ref, :seen, {topic, correlated}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, %{topic: topic, event: event, correlated: correlated}}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :listener_down}
    end
  end

  defp matched(message, topics, event, id, subject) do
    with {topic, ^event, payload} <- unwrap(message),
         true <- topic in topics,
         correlated when correlated != false <- correlation(payload, id, subject) do
      {topic, correlated}
    else
      _other -> false
    end
  end

  defp unwrap(%Phoenix.Socket.Broadcast{topic: topic, event: event, payload: payload}),
    do: {topic, event, payload}

  defp unwrap(%{topic: topic, event: event, payload: payload}), do: {topic, event, payload}
  defp unwrap(_other), do: nil

  # An Ash notification says which operation sent it, so only this receipt's counts; a payload a
  # publication transformed says nothing of the kind, and its record is all there is to go by.
  defp correlation(%Ash.Notifier.Notification{changeset: %{context: context}}, id, _subject) do
    get_in(context, [:shared, :receipt_id]) == id and :receipt
  end

  defp correlation(%Ash.Notifier.Notification{}, _id, _subject), do: false

  defp correlation(payload, _id, subject), do: record(payload, subject)

  defp record(%{id: id}, id) when not is_nil(id), do: :record
  defp record(_payload, _subject), do: false

  @doc false
  # The topics `ctx`'s action publishes to, from the options or the resource's `pub_sub` block.
  def topics(ctx, opts) do
    case Keyword.get(opts, :topics) do
      nil -> derived(ctx)
      topics when is_list(topics) -> topics
      check -> List.wrap(Stages.call(check, ctx))
    end
  end

  defp derived(%{resource: resource} = ctx) when is_atom(resource) and not is_nil(resource) do
    if Ash.Resource.Info.resource?(resource) and Info.publications(resource) != [] do
      prefix = Info.prefix(resource) || ""
      delimiter = Info.delimiter(resource)

      resource
      |> Info.publications()
      |> Enum.filter(&publishes?(&1, ctx))
      |> Enum.flat_map(&fill(&1.topic, ctx, delimiter))
      |> Enum.map(&prefixed(prefix, &1, delimiter))
      |> Enum.uniq()
    else
      []
    end
  end

  defp derived(_ctx), do: []

  defp publishes?(%{action: name}, %{action: name}) when not is_nil(name), do: true

  defp publishes?(%{type: type, except: except}, %{action_type: type, action: name})
       when not is_nil(type),
       do: name not in List.wrap(except)

  defp publishes?(_publication, _action), do: false

  defp event(ctx, opts) do
    Keyword.get_lazy(opts, :event, fn ->
      publication =
        ctx.resource
        |> Info.publications()
        |> Enum.find(&publishes?(&1, ctx))

      to_string((publication && publication.event) || ctx.action)
    end)
  end

  defp fill(topic, _ctx, _delimiter) when is_binary(topic), do: [topic]

  defp fill(topic, ctx, delimiter),
    do: topic |> combos(values(ctx), []) |> Enum.map(&Enum.join(&1, delimiter))

  defp combos([], _values, trail), do: [Enum.reverse(trail)]
  defp combos([nil | rest], values, trail), do: combos(rest, values, trail)

  defp combos([item | rest], values, trail) when is_binary(item),
    do: combos(rest, values, [item | trail])

  defp combos([item | rest], values, trail) when is_list(item),
    do: Enum.flat_map(item, &combos([&1 | rest], values, trail))

  defp combos([item | rest], values, trail) when is_atom(item) do
    case values.(item) do
      nil -> []
      value -> combos(rest, values, [to_string(value) | trail])
    end
  end

  # What a topic's atoms read before the action runs: the tenant, then the changeset's values.
  defp values(%{changeset: %Ash.Changeset{} = changeset}) do
    fn
      :_tenant -> changeset.to_tenant
      :_pkey -> changeset.data |> Map.get(:id) |> Redactor.id()
      field -> Ash.Changeset.get_attribute(changeset, field)
    end
  end

  defp values(%{site_id: site_id}) do
    fn
      :site_id -> site_id
      _other -> nil
    end
  end

  defp prefixed("", topic, _delimiter), do: topic
  defp prefixed(prefix, "", _delimiter), do: prefix
  defp prefixed(prefix, topic, delimiter), do: prefix <> delimiter <> topic

  defp subscribe(resource, topic) do
    case Info.name(resource) do
      nil -> Info.module(resource).subscribe(topic)
      pub_sub -> Phoenix.PubSub.subscribe(pub_sub, topic)
    end
  end
end
