# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Runtime.ShareCardQueue do
  @moduledoc """
  The Oban queue share cards are drawn on, `:share_cards`, and how many are drawn at once: the
  `share_cards.workers` setting (Settings → SEO → Share cards, master only), from 0 to 4, 1 by
  default. 0 pauses the queue: the cards wait in it, and are drawn once it is set above 0 again.

  Every job that draws a share card, or looks at one, runs on it:
  `MishkaCmsCore.Runtime.ShareCard` and `MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker`,
  and an extension's or a site's own drawing worker the same way, `use Oban.Worker, queue:
  :share_cards`. So a redraw of every card of a site — after its address changes — draws one card
  at a time, and never holds up a stylesheet build on `:assets`.

  A host lists the queue in its Oban `queues`, paused, and the boot starts it:

      config :my_app, Oban,
        queues: [default: 5, assets: 2, share_cards: [limit: 1, paused: true]]

  ## When the setting is applied

    * when it is saved: this module is a mishka_installer plugin on `cms_core:setting:after_save`,
      and scales, pauses or resumes the queue on every node of the cluster through Oban's notifier
      (`Oban.scale_queue/2`, `Oban.pause_queue/2`, `Oban.resume_queue/2`);
    * when a node starts: `MishkaCmsCore.Runtime.Handlers.BootHandler` calls `boot/1`, which applies
      the stored value to that node's own queue.

  Registered in `MishkaCmsCore.Application`.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook
  alias MishkaCmsCore.Runtime.Setting

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(Setting),
    initial: %{priority: 60}

  require Logger

  alias MishkaCmsCore.Settings

  @queue :share_cards
  @key "share_cards.workers"
  @default 1
  @max 4

  @doc "The queue every share-card job runs on."
  @spec queue() :: atom()
  def queue, do: @queue

  @doc "The setting that says how many share cards are drawn at once."
  @spec key() :: String.t()
  def key, do: @key

  @doc "The setting's definition, on the SEO tab of the settings page."
  @spec settings() :: [Settings.definition()]
  def settings do
    [
      Settings.define(@key, :integer,
        default: @default,
        min: 0,
        max: @max,
        category: "seo",
        group: gettext_noop("Share cards"),
        scope: :master,
        label: gettext_noop("Share-card workers"),
        description:
          gettext_noop(
            "How many share cards are drawn at the same time, from 0 to 4. Each one keeps a processor core busy while it draws. 0 pauses the drawing: new cards wait, and pages show their own image until it is set above 0 again."
          )
      )
    ]
  end

  @doc "How many share cards are drawn at once: the stored setting, within 0..4."
  @spec workers() :: 0..4
  def workers do
    case Settings.get(@key, @default) do
      workers when is_integer(workers) -> bound(workers)
      _not_a_number -> @default
    end
  end

  @doc """
  Draws `workers` share cards at once: the queue scaled to that many and resumed, or paused for 0.

  Options:

    * `:oban` — the Oban instance, `Oban` by default
    * `:local_only` — `true` for this node's queue alone; every node's by default

  `{:error, :not_running}` when that Oban instance is not running, and `{:error, :no_queue}` for
  `local_only: true` when this node runs no `:share_cards` queue.
  """
  @spec scale(integer(), keyword()) :: :ok | {:error, term()}
  def scale(workers, opts \\ []) when is_integer(workers) do
    oban = Keyword.get(opts, :oban, Oban)
    scope = Keyword.take(opts, [:local_only])

    cond do
      is_nil(Oban.whereis(oban)) ->
        {:error, :not_running}

      scope[:local_only] && is_nil(Oban.check_queue(oban, queue: @queue)) ->
        {:error, :no_queue}

      bound(workers) == 0 ->
        Oban.pause_queue(oban, [queue: @queue] ++ scope)

      true ->
        with :ok <- Oban.scale_queue(oban, [queue: @queue, limit: bound(workers)] ++ scope),
             do: Oban.resume_queue(oban, [queue: @queue] ++ scope)
    end
  end

  @doc """
  Applies the stored setting to this node's queue (`scale/2` with `local_only: true`), and says so
  in the log when the queue is not in the app's Oban `queues`. Takes `scale/2`'s `:oban`.
  """
  @spec boot(keyword()) :: :ok | {:error, term()}
  def boot(opts \\ []) do
    case scale(workers(), Keyword.put(opts, :local_only, true)) do
      :ok ->
        :ok

      {:error, :no_queue} = error ->
        Logger.warning(
          "[ShareCardQueue] No #{inspect(@queue)} queue runs on this node, so no share card is drawn here. Add `#{@queue}: [limit: 1, paused: true]` to the app's Oban queues."
        )

        error

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def call(%Setting{key: @key, site_id: nil, value: %{"value" => workers}} = setting, _meta)
      when is_integer(workers) do
    _ = scale(workers)
    {:reply, setting}
  end

  def call(setting, _meta), do: {:reply, setting}

  defp bound(workers), do: workers |> max(0) |> min(@max)
end
