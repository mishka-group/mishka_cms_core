# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Activity.Sources.RuntimeCompile do
  @moduledoc """
  Activity source for on-demand (lazy) runtime module compiles.

  A lazy runtime part (`precompile: false`, e.g. a Page) is compiled inside the
  visitor's web request on first hit — there is no Oban job, so neither the
  runtime status panel nor the activity feed would otherwise hear about it. The
  compiler emits a lightweight telemetry event (`[:mishka_cms, :runtime, :compiler,
  :compiled]`) — fire-and-forget, no blocking, no side effects in the compile path
  — and this source bridges it to PubSub, exactly like
  `MishkaCmsCore.Activity.Sources.Oban` bridges Oban job telemetry.

  Attached once on boot via `attach/0` (from `MishkaCmsCore.Application.start/2`).

  ## Topics
    * `runtime_compiled:res:<resource>` — compiles of one resource (any site)
    * `runtime_compiled:site:<id>:res:<resource>` — one resource on one site

  No `initial_fetch/2` history: lazy compiles are ephemeral (not persisted), so
  the feed shows them live but they do not appear in the historical activity log.
  """
  @behaviour MishkaCmsCore.Activity.Behaviours.Source

  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Activity.Helpers

  @topic "runtime_compiled"
  @handler_id "mishka-cms-core-activity-runtime-compile"
  @event [:mishka_cms, :runtime, :compiler, :compiled]

  @doc "Attach the compiler telemetry → PubSub bridge. Idempotent."
  def attach do
    :telemetry.detach(@handler_id)
    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_telemetry/4, nil)
  end

  @doc false
  def handle_telemetry(@event, _measurements, %{module: module} = meta, _config) do
    site_id = meta[:site_id]
    resource = runtime_resource(module)
    payload = %{__runtime_compiled__: true, module: module, resource: resource, site_id: site_id}

    broadcast(res_topic(resource), payload)
    if site_id, do: broadcast(site_res_topic(site_id, resource), payload)
    :ok
  end

  def handle_telemetry(_event, _measurements, _meta, _config), do: :ok

  @impl true
  def topics(scope) do
    case {Helpers.reach(scope[:current_user]), scope_resources(scope)} do
      {:everything, mods} when is_list(mods) -> Enum.map(mods, &res_topic/1)
      {{:site, id}, mods} when is_list(mods) -> Enum.map(mods, &site_res_topic(id, &1))
      _nothing_or_unscoped -> []
    end
  end

  @impl true
  def handles?(%Phoenix.Socket.Broadcast{payload: %{__runtime_compiled__: true}}), do: true
  def handles?(_message), do: false

  @impl true
  def to_entry(%Phoenix.Socket.Broadcast{payload: %{__runtime_compiled__: true} = payload}) do
    now = DateTime.utc_now()
    label = short_resource(payload.resource)

    %{
      id: "compiled-#{inspect(payload.module)}-#{DateTime.to_unix(now, :microsecond)}",
      resource_label: label,
      action: :compiled,
      severity: :info,
      badge_label: gettext("COMPILE"),
      badge_tone: :sky,
      # Compiling a template changes nothing in the document, so no content tone.
      tone: nil,
      inserted_at: now,
      source_id: nil,
      site_id: payload[:site_id],
      user_id: nil,
      message: gettext("%{label} compiled on first request", label: label)
    }
  end

  def to_entry(_message), do: nil

  @impl true
  def initial_fetch(_scope, _limit), do: []

  defp broadcast(topic, payload) do
    Phoenix.PubSub.broadcast(
      MishkaCmsCore.PubSub,
      topic,
      %Phoenix.Socket.Broadcast{topic: topic, event: @topic, payload: payload}
    )
  end

  defp res_topic(resource), do: "#{@topic}:res:#{inspect(resource)}"
  defp site_res_topic(id, resource), do: "#{@topic}:site:#{id}:res:#{inspect(resource)}"

  defp runtime_resource(module) do
    type = module |> Module.split() |> List.last()
    Module.concat([MishkaCmsCore.Runtime, type])
  end

  defp short_resource(resource),
    do: resource |> Module.split() |> List.last() |> Helpers.translate()

  defp scope_resources(%{resources: list}) when is_list(list) and list != [], do: list
  defp scope_resources(_scope), do: nil
end
