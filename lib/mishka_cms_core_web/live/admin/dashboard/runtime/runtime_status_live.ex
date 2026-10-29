# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCoreWeb.Live.Admin.Dashboard.Runtime.RuntimeStatusLive do
  @moduledoc """
  Shared expanded-row wiring for every runtime admin table (Component, Layout,
  ErrorPage, Page, Stylesheet, JsHook). The expanded row shows the record's real
  runtime status (`MishkaCmsCore.Runtime.RuntimeStatus`) as a live timeline that
  refreshes while open.

  Each page keeps its own `handle_info/2` and `handle_async/3` clauses (so they
  stay grouped) and delegates the body here:

      def mount(_p, _s, socket) do
        socket =
          RuntimeStatusLive.setup(socket,
            resource: MishkaCmsCore.Runtime.JsHook,
            table_id: "js-hooks-table",
            master_action: :master_get,
            tenant_action: :get_for_tenant_with_globals,
            master_load: [:site],
            tenant_load: [:site]
          )

        # ...then ActivityFeed.setup(socket, ...) — AFTER this call.
      end

      def handle_info({:expand_row, id}, socket),
        do: {:noreply, RuntimeStatusLive.expand(socket, id)}

      def handle_async({:runtime_status_load, _id}, result, socket),
        do: {:noreply, RuntimeStatusLive.loaded(socket, result)}

  `setup/2` MUST run before `ActivityFeed.setup/2`: the feed attaches a hook that
  `{:halt}`s Oban broadcasts, and the realtime refresh here needs to see them
  first. `tenant_action: nil` omits the `action:` option for tenant reads (the
  resource's default tenant read), used by ErrorPage and Page.
  """
  use Phoenix.Component
  use Gettext, backend: MishkaCmsCore.Gettext

  import Phoenix.LiveView, only: [attach_hook: 4, send_update: 2, connected?: 1]

  alias MishkaCmsCore.Runtime.Compilers.Helpers
  alias MishkaCmsCore.Runtime.RuntimeStatus
  alias MishkaCmsCoreWeb.Live.Admin.Components.RuntimeStatusTimeline

  @doc "Init expanded-row state and attach the realtime Oban refresh hook."
  def setup(socket, opts) do
    config = %{
      resource: Keyword.fetch!(opts, :resource),
      table_id: Keyword.fetch!(opts, :table_id),
      master_action: Keyword.get(opts, :master_action, :master_get),
      tenant_action: Keyword.get(opts, :tenant_action),
      master_load: Keyword.get(opts, :master_load, [:site]),
      tenant_load: Keyword.get(opts, :tenant_load, [:site])
    }

    socket
    |> assign(:expanded_id, nil)
    |> assign(:expanded_module, nil)
    |> assign(:asset_topic, nil)
    |> assign(:runtime_status_opts, config)
    |> attach_hook(:runtime_status_oban, :handle_info, &oban_hook/2)
  end

  @doc "Track the open row and load its status off the LiveView process."
  def expand(socket, id) do
    config = socket.assigns.runtime_status_opts
    actor = socket.assigns.current_user

    socket
    |> assign(:expanded_id, id)
    |> MishkaGervaz.Messages.start_async({:runtime_status_load, id}, fn ->
      load_record(id, actor, config)
    end)
  end

  @doc "Render the loaded record's status into the gervaz expanded row."
  def loaded(socket, {:ok, %{record: nil}}) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: socket.assigns.runtime_status_opts.table_id,
      expanded_html: render_gone_html()
    )

    assign(socket, :expanded_module, nil)
  end

  def loaded(socket, {:ok, %{record: record}}) do
    config = socket.assigns.runtime_status_opts
    status = RuntimeStatus.compute(record, config.resource)

    send_update(MishkaGervaz.Table.Web.Live,
      id: config.table_id,
      expanded_html: render_html(status, record)
    )

    socket
    |> maybe_subscribe_assets(status)
    |> assign(:expanded_module, status.module)
  end

  def loaded(socket, {:exit, reason}) do
    send_update(MishkaGervaz.Table.Web.Live,
      id: socket.assigns.runtime_status_opts.table_id,
      expanded_error: reason
    )

    socket
  end

  @doc "Re-load the open row, if any (used by realtime refresh paths)."
  def refresh(%{assigns: %{expanded_id: nil}} = socket), do: socket
  def refresh(%{assigns: %{expanded_id: id}} = socket), do: expand(socket, id)

  @doc """
  Refresh the open row when an Ash notification targets it (instant feedback on
  active/precompile toggles, before the compile job's Oban event lands). Call
  from the page's existing resource-notification `handle_info/2` clause.
  """
  def refresh_if_match(socket, %Ash.Notifier.Notification{data: %{id: id}}) do
    if match_open?(socket, id), do: refresh(socket), else: socket
  end

  def refresh_if_match(socket, _notification), do: socket

  defp oban_hook(
         %Phoenix.Socket.Broadcast{event: "oban_activity", payload: %{__oban__: true, job: job}},
         socket
       ) do
    if match_open?(socket, job_record_id(job)),
      do: {:cont, refresh(socket)},
      else: {:cont, socket}
  end

  # On-demand (lazy) compile of a runtime module — see Activity.Sources.RuntimeCompile.
  # Matched by compiled module against the open record's module. `:cont` so the
  # ActivityFeed hook (attached after this one) still forwards it to the feed; the
  # feed's forward halts it so it never reaches an unmatched LiveView handle_info.
  defp oban_hook(
         %Phoenix.Socket.Broadcast{payload: %{__runtime_compiled__: true, module: module}},
         socket
       ) do
    if socket.assigns[:expanded_module] && socket.assigns.expanded_module == module,
      do: {:cont, refresh(socket)},
      else: {:cont, socket}
  end

  # Asset-backed records (Stylesheet/JsHook) live in the SITE's combined bundle,
  # rebuilt by a separate :assets job that broadcasts these on `site:<name>:assets`.
  # Halt: consumed here (no LiveView handle_info clause for them).
  defp oban_hook({:css_updated, _hash}, socket), do: {:halt, refresh(socket)}
  defp oban_hook({:js_updated, _hash}, socket), do: {:halt, refresh(socket)}
  defp oban_hook({:asset_build, _bundle, _type}, socket), do: {:halt, refresh(socket)}

  defp oban_hook(_message, socket), do: {:cont, socket}

  # The asset bundle's compile job carries no record id, so the per-record oban match
  # never sees it. Subscribe the open asset row to its bundle's asset-update broadcast
  # and its build record, and refresh when either changes — the status flips Bundled →
  # Live, or to a failed build. A global row is in every site's bundle, so it hears
  # every bundle's build record.
  defp maybe_subscribe_assets(socket, %{mode: :asset, site_name: site_name}) do
    topics = site_name |> RuntimeStatus.asset_bundle_id() |> asset_topics()

    cond do
      !connected?(socket) ->
        socket

      socket.assigns[:asset_topic] == topics ->
        socket

      true ->
        for topic <- List.wrap(socket.assigns[:asset_topic]),
            do: Phoenix.PubSub.unsubscribe(MishkaCmsCore.PubSub, topic)

        for topic <- topics, do: Phoenix.PubSub.subscribe(MishkaCmsCore.PubSub, topic)
        assign(socket, :asset_topic, topics)
    end
  end

  defp maybe_subscribe_assets(socket, _status), do: socket

  defp asset_topics("__shared_base__" = bundle),
    do: ["site:#{bundle}:assets", Helpers.asset_builds_topic(:all)]

  defp asset_topics(bundle), do: ["site:#{bundle}:assets", Helpers.asset_builds_topic(bundle)]

  defp match_open?(%{assigns: %{expanded_id: nil}}, _id), do: false
  defp match_open?(_socket, nil), do: false
  defp match_open?(%{assigns: %{expanded_id: open}}, id), do: to_string(open) == to_string(id)

  defp job_record_id(%{args: %{"data" => %{"id" => id}}}), do: id
  defp job_record_id(_job), do: nil

  defp load_record(id, %{site_id: nil} = actor, config) do
    %{
      record:
        get_record(config.resource, id,
          action: config.master_action,
          actor: actor,
          load: config.master_load
        )
    }
  end

  defp load_record(id, %{site_id: site_id} = actor, config) when is_binary(site_id) do
    opts =
      [actor: actor, tenant: site_id, load: config.tenant_load]
      |> maybe_put_action(config.tenant_action)

    %{record: get_record(config.resource, id, opts)}
  end

  # The expanded row can outlive its record (e.g. a permanent delete while open), so a miss
  # returns nil instead of raising — `loaded/2` renders a "gone" note rather than crashing.
  defp get_record(resource, id, opts) do
    case Ash.get(resource, id, opts) do
      {:ok, record} -> record
      {:error, _} -> nil
    end
  end

  defp maybe_put_action(opts, nil), do: opts
  defp maybe_put_action(opts, action), do: Keyword.put(opts, :action, action)

  defp render_gone_html do
    assigns = %{}

    ~H"""
    <div class="px-4 py-3 text-sm text-zinc-400">{gettext("This record no longer exists.")}</div>
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render_html(status, record) do
    assigns = %{status: status, record: record}

    ~H"""
    <RuntimeStatusTimeline.timeline status={@status} record={@record} />
    """
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
