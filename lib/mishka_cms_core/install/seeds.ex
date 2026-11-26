# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Install.Seeds do
  @moduledoc """
  Every choice the installer offers, in development and in production, as the parts plugins declare
  on the `installer:seed` event (`event/0`).

  The production install (`MishkaCmsCore.Install.Bootstrap`) runs the `:prod` parts; the installer's
  "load sample data" path and the host's seed scripts run the `:dev` parts. Subscribing is declaring,
  as it is for `installer:extension:install` (`MishkaCmsCore.Install.Extensions`): the installer's
  own registry says which plugins exist, in which order and which an operator switched off, and
  `plugins/1` reads it. No list of parts is kept here.

  ## A plugin's `extra` is a list of parts

      defmodule MyExtension.Plugins.Seed do
        use MishkaInstaller.Event.Hook,
          event: "installer:seed",
          initial: %{
            priority: 50,
            extra: [
              %{
                id: "pages",
                label: "Pages and components",
                summary: "The pages, components and permissions the extension runs on",
                envs: [:dev, :prod],
                default: true
              },
              %{
                id: "samples",
                label: "Sample data",
                summary: "Sample records on every dev site",
                envs: [:dev],
                default: true,
                nav: [%{label: "Sample mine", path: "/samples/mine"}]
              }
            ]
          }

        alias MishkaCmsCore.Install.Extensions

        @impl true
        def call(%{key: "my_extension", part: "pages"} = payload) do
          report =
            case Extensions.install(payload.site_id, "my_extension", payload.answers) do
              {:ok, report} -> report
              {:error, reason} -> %{error: reason}
            end

          {:reply, %{payload | reports: payload.reports ++ [report]}}
        end

        def call(%{key: "my_extension", part: "samples"} = payload) do
          report =
            case payload.size do
              :normal -> MyExtension.Dev.Seeds.dev_seed(payload.site_id, payload.users, payload.progress)
              :stress -> MyExtension.Dev.Seeds.stress_seed(payload.site_id, payload.users)
            end

          {:reply, %{payload | reports: payload.reports ++ [report]}}
        end

        def call(payload), do: {:reply, payload}
      end

  Each part is `%{id:, label:, summary:, envs:, required:, default:, nav:}`:

    * `id` names the part. It is what a selection lists, what the payload's `part` says and, with
      the plugin's key, the row of the installer's checklist (`{key, id}`). A map without one is not
      a part and is passed over.
    * `envs` says which installer shows it: `[:dev]` the sample-data path, `[:prod]` the real
      install, `[:dev, :prod]` both. A part that names none is `[:dev]`.
    * `required: true` is shown ticked and locked, and runs whatever was chosen.
    * `default: true` starts ticked and can be unticked; `false` (the default) starts unticked.
    * `nav` is the links the part's pages are reached by, added to every dev site's `Dev` header
      dropdown (`nav/0`): `%{label:, path:}` is stored under the site's `/:lang`, `%{label:, to:}`
      as the literal path, for a page that answers no language. The links of the extension itself
      (Blog, Docs) are not a part's: its `installer:extension:install` plugin declares them once
      (`MishkaCmsCore.Install.Extensions`), its first install adds them to a site's header and
      `nav/0` lists them in the `Dev` dropdown as well.

  An extension's "pages" part goes through `MishkaCmsCore.Install.Extensions.install/4`, so
  `installer:extension:install` still does the writing and the site is recorded as set up
  (`<app>.installed`). The fields its `installer:extension:install` plugin declares are asked under
  its row, and arrive as `answers`.

  ## Running

  The run order is the plugins' priority, then the parts in the order each plugin declares them.
  The core's own plugin (`MishkaCmsCore.Install.CoreSeed`) comes first and its parts run once,
  before there is a site: each one's report is merged into the `foundation` the next one is handed
  (`sites`, `users: %{master:, tenant:}`, `permissions`, and in production `site` and `user`).
  Every other plugin's part then runs once per site of the foundation.

  A part is fired with:

      %{
        key: "my_extension",          # whose part it is; a plugin ignores any other key
        part: "pages",                # the part to run
        parts: ["pages", "samples"],  # every part of this plugin the run chose, in run order
        env: :prod,                   # :dev for the sample-data path, :prod for a real install
        size: :normal,                # :stress for the host's large-volume dev run
        site_id: "…",                 # nil for the core's parts, which run before there is a site
        users: [user, …],             # the master users, then this site's own; [] for the core's
        answers: %{},                 # what the installer asked this plugin
        foundation: %{sites: […], …}, # what the core's parts built
        opts: [],                     # the run's options, a stress run's volumes
        progress: fn line -> … end,   # a line for the part's row of the checklist
        reports: []                   # the plugin whose key it is appends its report
      }

  The plugin whose key it is appends one report. `%{error: reason}` is a failure, and so are a
  plugin that raised, one that is not loaded and a part nothing answered: a part that did nothing
  must not read as one that worked. A failed required part stops the run with `{:error, reason}`;
  a failed optional part is marked on its row and logged, and the run goes on, so one extension
  cannot take an install down with it.

  ## Never a dev part in production

  A build whose config sets neither `:env_dev?` nor `:env_test?` is a production build. There a
  `:dev` run is refused, and a part whose `envs` lack `:prod` is not run whatever a selection says:
  the guard is here, not in the installer's screen.
  """
  use Gettext, backend: MishkaCmsCore.Gettext

  require Logger

  alias MishkaCmsCore.Install.Extensions
  alias MishkaInstaller.Event.Hook

  @event "installer:seed"

  # THE CORE'S OWN PARTS BUILD WHAT EVERY OTHER PART RUNS ON: the permissions, the masters and the
  # sites. They run once and first; see `MishkaCmsCore.Install.CoreSeed`.
  @core "mishka_cms_core"

  @type env :: :dev | :prod

  @typedoc "A link a part's pages are reached by; see the moduledoc."
  @type nav_link :: Extensions.nav_link()

  @typedoc "One part of a plugin, read from its `extra`; see the moduledoc."
  @type part :: %{
          id: String.t(),
          label: String.t(),
          summary: String.t(),
          envs: [env()],
          required: boolean(),
          default: boolean(),
          nav: [nav_link()]
        }

  @typedoc """
  A plugin on the event, with the parts the asked-for installer shows. `key` is its OTP app as a
  string; `label` is the name its `installer:extension:install` plugin gives it, if it has one.
  """
  @type plugin :: %{
          key: String.t(),
          app: atom(),
          plugin: module(),
          label: String.t(),
          priority: integer(),
          parts: [part()]
        }

  @typedoc "A row of the installer's checklist: the plugin's key and the part's id."
  @type row :: {String.t(), String.t()}

  @typedoc """
  What was chosen: each plugin's key and the ids of its parts that were ticked. A required part runs
  whether it is listed or not. A plugin the map does not name, and every plugin when it is `nil`,
  runs what is ticked at the start: its required and default parts.
  """
  @type picks :: %{optional(String.t()) => [String.t()]} | nil

  @doc "The event a plugin subscribes to in order to offer parts to the installer."
  @spec event() :: String.t()
  def event, do: @event

  @doc "The key of the core's own plugin, whose parts run once and first."
  @spec core_key() :: String.t()
  def core_key, do: @core

  @doc """
  The plugins the `env` installer shows, the core's first and the rest by priority, each with the
  parts it shows there. A plugin an operator switched off, one held by a dependency, and one with no
  part for `env` are left out. In a production build a part without `:prod` is left out too.
  """
  @spec plugins(env()) :: [plugin()]
  def plugins(env) when env in [:dev, :prod] do
    labels = Map.new(Extensions.installable(), &{&1.key, &1.label})

    @event
    |> Extensions.offered()
    |> Enum.map(&plugin(&1, env, labels))
    |> Enum.reject(&(&1.parts == []))
    |> Enum.sort_by(&(&1.key != @core))
  end

  @doc """
  The rows a run of `picks` shows, as `{row, label}`, in the order it runs them: one per chosen
  part of each plugin.
  """
  @spec steps(env(), picks()) :: [{row(), String.t()}]
  def steps(env, picks \\ nil) do
    for plugin <- chosen(env, picks),
        part <- plugin.parts,
        do: {{plugin.key, part.id}, part.label}
  end

  @doc """
  The links of every plugin with a `:dev` part, in the order the parts run, for the `Dev` dropdown
  of every dev site's header: the extension's own `nav` (what its `installer:extension:install`
  plugin declares, `MishkaCmsCore.Install.Extensions`, and its first install adds to a site's
  header), then the `nav` of each of its `:dev` parts.
  """
  @spec nav() :: [nav_link()]
  def nav do
    installed = Map.new(Extensions.installable(), &{&1.key, &1.nav})

    for plugin <- plugins(:dev),
        link <- Map.get(installed, plugin.key, []) ++ Enum.flat_map(plugin.parts, & &1.nav),
        do: link
  end

  @doc """
  Runs the chosen parts of every plugin for the `env` installer, and returns the foundation the
  core's parts built.

  `opts`:

    * `:answers`: what the installer asked each plugin, by key. A plugin is handed its own.
    * `:progress`: called with `{row, :running | :log | :done | :error, detail}` as each part
      starts, writes a line, finishes or fails, for a live checklist.
    * `:size`: `:normal`, or `:stress` for the host's large-volume dev run.
    * anything else is handed to every part as `opts`.

  Returns `{:ok, foundation}`, or `{:error, reason}` from the first required part that failed. A
  `:dev` run in a production build is `{:error, :dev_in_production}`, and nothing runs.
  """
  @spec run(env(), picks(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(env, picks \\ nil, opts \\ [])

  def run(:dev, picks, opts) do
    if production_build?(), do: {:error, :dev_in_production}, else: run_parts(:dev, picks, opts)
  end

  def run(:prod, picks, opts), do: run_parts(:prod, picks, opts)

  @doc """
  Every `:dev` part of every plugin, for a script such as the host's `priv/repo/dev_seeds.exs`:
  `run/3` with all of them chosen, default or not. `run_all(:stress, opts)` runs them at
  `size: :stress` and hands `opts` (the volumes, and an optional `:progress`) to every part.
  Returns the foundation, and raises when a required part failed.
  """
  @spec run_all(:normal | :stress, keyword()) :: map()
  def run_all(size \\ :normal, opts \\ []) when size in [:normal, :stress] do
    picks = Map.new(plugins(:dev), &{&1.key, Enum.map(&1.parts, fn part -> part.id end)})

    case run(:dev, picks, Keyword.put(opts, :size, size)) do
      {:ok, foundation} -> foundation
      {:error, reason} -> raise "the seeds did not run: #{describe(reason)}"
    end
  end

  @doc """
  Whether this is a production build: its config sets neither `:env_dev?` nor `:env_test?`.
  """
  @spec production_build?() :: boolean()
  def production_build? do
    Application.get_env(:mishka_cms_core, :env_dev?) != true and
      Application.get_env(:mishka_cms_core, :env_test?) != true
  end

  defp run_parts(env, picks, opts) do
    {progress, opts} = Keyword.pop(opts, :progress, fn _message -> :ok end)
    {answers, opts} = Keyword.pop(opts, :answers, %{})
    {size, opts} = Keyword.pop(opts, :size, :normal)

    run = %{env: env, size: size, opts: opts, answers: answers, progress: progress}
    {core, others} = env |> chosen(picks) |> Enum.split_with(&(&1.key == @core))

    with {:ok, foundation} <- run_once(core, run),
         :ok <- run_per_site(others, foundation, run),
         do: {:ok, foundation}
  end

  defp chosen(env, picks) do
    for plugin <- plugins(env),
        parts = Enum.filter(plugin.parts, &picked?(&1, picks, plugin.key)),
        parts != [],
        do: %{plugin | parts: parts}
  end

  defp picked?(%{required: true}, _picks, _key), do: true
  defp picked?(part, nil, key), do: picked?(part, %{}, key)

  defp picked?(%{id: id, default: default}, picks, key) do
    case Map.fetch(picks, key) do
      {:ok, ids} -> id in Enum.map(List.wrap(ids), &to_string/1)
      :error -> default
    end
  end

  defp run_once(plugins, run) do
    plugins
    |> parts_in_order()
    |> Enum.reduce_while({:ok, %{}}, fn {plugin, part}, {:ok, foundation} ->
      context = %{site_id: nil, users: [], foundation: foundation}

      case run_row(plugin, part, [context], run) do
        {:ok, [report]} when is_map(report) -> {:cont, {:ok, Map.merge(foundation, report)}}
        {:ok, _reports} -> {:cont, {:ok, foundation}}
        {:error, reason} -> failed(part, reason, {:ok, foundation})
      end
    end)
  end

  defp run_per_site(plugins, foundation, run) do
    users = Map.get(foundation, :users, %{})
    masters = Map.get(users, :master, [])
    tenant = Map.get(users, :tenant, %{})

    contexts =
      for site <- Map.get(foundation, :sites, []) do
        %{
          site_id: site.id,
          users: masters ++ Map.get(tenant, site.id, []),
          foundation: foundation
        }
      end

    plugins
    |> parts_in_order()
    |> Enum.reduce_while(:ok, fn {plugin, part}, :ok ->
      case run_row(plugin, part, contexts, run) do
        {:ok, _reports} -> {:cont, :ok}
        {:error, reason} -> failed(part, reason, :ok)
      end
    end)
  end

  defp parts_in_order(plugins),
    do: for(plugin <- plugins, part <- plugin.parts, do: {plugin, part})

  defp failed(%{required: true}, reason, _going_on), do: {:halt, {:error, reason}}
  defp failed(_optional, _reason, going_on), do: {:cont, going_on}

  # ONE ROW PER PART, however many sites it runs on, and it stops at the first site that failed.
  defp run_row(plugin, part, contexts, run) do
    row = {plugin.key, part.id}
    run.progress.({row, :running, nil})
    line = fn text -> run.progress.({row, :log, text}) end

    contexts
    |> Enum.reduce_while({:ok, []}, fn context, {:ok, reports} ->
      case fire(plugin, part, context, line, run) do
        {:ok, report} -> {:cont, {:ok, [report | reports]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reports} ->
        run.progress.({row, :done, nil})
        {:ok, Enum.reverse(reports)}

      {:error, reason} = error ->
        Logger.error("[Install] #{plugin.key} #{part.id} did not run: #{inspect(reason)}")
        run.progress.({row, :error, describe(reason)})
        error
    end
  end

  defp fire(plugin, part, context, line, run) do
    payload =
      Map.merge(context, %{
        key: plugin.key,
        part: part.id,
        parts: Enum.map(plugin.parts, & &1.id),
        env: run.env,
        size: run.size,
        answers: Map.get(run.answers, plugin.key, %{}),
        opts: run.opts,
        progress: line,
        reports: []
      })

    @event
    |> Hook.call(payload, cannot_run: :cannot_run, raised: :raised)
    |> answer()
  end

  defp answer(%{reports: [%{error: reason} | _rest]}), do: {:error, reason}
  defp answer(%{reports: [report | _rest]}), do: {:ok, report}
  defp answer(%{reports: []}), do: {:error, :no_plugin_answered}
  defp answer(:cannot_run), do: {:error, :plugin_not_loaded}
  defp answer(:raised), do: {:error, :plugin_raised}
  defp answer(_other), do: {:error, :payload_not_handed_back}

  @doc false
  @spec describe(term()) :: String.t()
  def describe(:no_plugin_answered), do: gettext("no plugin answered to it")
  def describe(:plugin_not_loaded), do: gettext("its plugin is not loaded")
  def describe(:plugin_raised), do: gettext("its plugin raised, the log says why")
  def describe(:payload_not_handed_back), do: gettext("its plugin did not hand the payload back")

  def describe(:dev_in_production),
    do: gettext("sample data is never loaded in a production build")

  def describe(error) when is_exception(error), do: Exception.message(error)
  def describe(error) when is_binary(error), do: error
  def describe(error), do: inspect(error)

  defp plugin(entry, env, labels) do
    %{
      key: entry.key,
      app: entry.app,
      plugin: entry.plugin,
      label: plugin_label(entry, labels),
      priority: entry.priority,
      parts:
        for(
          extra <- entry.extra,
          part <- part(extra),
          shown?(part, env),
          do: part
        )
    }
  end

  defp plugin_label(%{key: @core}, _labels), do: gettext("Mishka CMS")

  defp plugin_label(%{key: key, app: app}, labels),
    do: Map.get_lazy(labels, key, fn -> Extensions.humanise(app) end)

  defp shown?(%{envs: envs}, env),
    do: env in envs and (:prod in envs or not production_build?())

  # AN `extra` HAS BEEN THROUGH MNESIA and a struct builder on its way here, so each key is read
  # for either kind, as `MishkaCmsCore.Install.Extensions` reads its own.
  defp part(extra) when is_map(extra) do
    case field(extra, :id) do
      id when is_binary(id) and id != "" ->
        required = field(extra, :required) == true

        [
          %{
            id: id,
            label: field(extra, :label) || id,
            summary: field(extra, :summary) || "",
            envs: envs(field(extra, :envs)),
            required: required,
            default: required or field(extra, :default) == true,
            nav: extra |> field(:nav) |> Extensions.nav()
          }
        ]

      _no_id ->
        []
    end
  end

  defp part(_extra), do: []

  defp envs(nil), do: [:dev]
  defp envs(envs), do: envs |> List.wrap() |> Enum.flat_map(&env/1) |> Enum.uniq()

  defp env(env) when env in [:dev, "dev"], do: [:dev]
  defp env(env) when env in [:prod, "prod"], do: [:prod]
  defp env(_unknown), do: []

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
