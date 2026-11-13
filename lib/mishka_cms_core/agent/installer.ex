# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Agent.Installer do
  @moduledoc """
  Installer steps with receipts: a runtime library installed or removed, a plugin's lifecycle, and
  an extension set up on a site. Each function calls the installer exactly as a caller would and
  returns what it returns, with the receipt beside it: `{result, receipt}`.

  `mishka_installer` knows nothing of receipts (the core depends on it, not the other way), so the
  steps are observed from here: after the installer answers, its own registry and the node are read
  again, separately from the answer.

  It is also the `"agent:operations"` plugin that declares these operations, so their receipts are
  read by full admins (libraries and plugins change the code every site runs) and by the site's
  admins (an extension set up on their site).

  | Operation | Checked |
  |---|---|
  | `installer:library:install` | the library's record in the installer's Mnesia registry at the asked version (db); the application loaded at that version on this node (app) |
  | `installer:library:uninstall` | the record gone (db); the application no longer loaded on this node (app) |
  | `installer:plugin:<step>` | `register`, `start`, `restart`, `stop`, `enable`, `unregister`: the plugin's record and status in the registry (db); for `start`, `restart` and `enable`, its health (app, not required) |
  | `installer:extension:install` | the site's `<app>.installed` row written during the operation (db); the settings cache naming the version the extension reported (app); nothing skipped in the report (app; a skipped or renamed page makes the receipt `:partial`) |

  ## What it does not prove

  A library or a plugin is checked on this node only: the installer syncs others through Mnesia
  and their state is not read. A loaded application is not proof its supervision tree is healthy. An
  extension's report is the extension's own account of the pages and components it wrote; only the
  install record is read back.
  """
  use MishkaCmsCore.Agent.Operation

  alias MishkaCmsCore.Agent.{Operation, Receipts}
  alias MishkaCmsCore.Install.Extensions
  alias MishkaInstaller.Event.{Event, Hook}
  alias MishkaInstaller.Installer.Installer, as: Library

  @plugin_steps [:register, :start, :restart, :stop, :enable, :unregister]
  @healthy_steps [:start, :restart, :enable]
  @site_areas ["admin:dashboard:runtime:site", "admin:api:runtime:site"]

  @plugin_statuses %{
    register: [:registered, :started, :held],
    start: [:started],
    restart: [:restarted, :started],
    stop: [:stopped],
    enable: [:restarted, :started]
  }

  @operations [
                Operation.new!(%{
                  name: "installer:library:install",
                  description: "A runtime library installed from its built package.",
                  stages: [
                    :dispatched,
                    :action_committed,
                    {:side_effect, :registry_record,
                     layer: :db, check: &__MODULE__.library_recorded/1},
                    {:side_effect, :code_loaded, check: &__MODULE__.library_loaded/1}
                  ],
                  required: [:action_committed, :registry_record, :code_loaded]
                }),
                Operation.new!(%{
                  name: "installer:library:uninstall",
                  description: "A runtime library stopped, unloaded and removed.",
                  stages: [
                    :dispatched,
                    :action_committed,
                    {:side_effect, :registry_record,
                     layer: :db, check: &__MODULE__.library_gone/1},
                    {:side_effect, :code_unloaded, check: &__MODULE__.library_unloaded/1}
                  ],
                  required: [:action_committed, :registry_record, :code_unloaded]
                }),
                Operation.new!(%{
                  name: "installer:extension:install",
                  description: "An extension set up on a site.",
                  visibility: @site_areas,
                  stages: [
                    :dispatched,
                    :action_committed,
                    {:db_read_back, :installed_record,
                     resource: MishkaCmsCore.Runtime.Setting,
                     by: &__MODULE__.installed_row/1,
                     expect: [updated_at: :since_start]},
                    {:side_effect, :installed_version, check: &__MODULE__.installed_version/1},
                    {:side_effect, :report_complete, check: &__MODULE__.report_complete/1}
                  ],
                  required: [
                    :action_committed,
                    :installed_record,
                    :installed_version,
                    :report_complete
                  ]
                })
              ] ++
                for(
                  step <- @plugin_steps,
                  do:
                    Operation.new!(%{
                      name: "installer:plugin:#{step}",
                      description: "A plugin's #{step} in the installer's registry.",
                      stages:
                        [
                          :dispatched,
                          :action_committed,
                          {:side_effect, :registry_status,
                           layer: :db, check: {__MODULE__, :plugin_status, [step]}}
                        ] ++
                          if(step in @healthy_steps,
                            do: [
                              {:side_effect, :plugin_health, check: &__MODULE__.plugin_health/1}
                            ],
                            else: []
                          ),
                      required: [:action_committed, :registry_status]
                    })
                )

  @impl MishkaCmsCore.Agent.Operation
  def operations, do: @operations

  @doc """
  `MishkaInstaller.Installer.Installer.install/1` of `library` (`%{app:, version:, path:}`), with
  its receipt. `opts` are `MishkaCmsCore.Agent.Receipts.track/3`'s (`:actor`, `:source`).
  """
  @spec install_library(map(), keyword()) :: {term(), MishkaCmsCore.Agent.Receipt.t() | nil}
  def install_library(library, opts \\ []) do
    Receipts.track(
      "installer:library:install",
      Keyword.put(opts, :params, library_params(library)),
      fn _id -> Library.install(library) end
    )
  end

  @doc "`MishkaInstaller.Installer.Installer.uninstall/1` of `library`, with its receipt."
  @spec uninstall_library(map(), keyword()) :: {term(), MishkaCmsCore.Agent.Receipt.t() | nil}
  def uninstall_library(library, opts \\ []) do
    Receipts.track(
      "installer:library:uninstall",
      Keyword.put(opts, :params, library_params(library)),
      fn _id -> Library.uninstall(library) end
    )
  end

  @doc """
  One lifecycle `step` of the plugin `module` (`#{inspect(@plugin_steps)}`), as the plugin's own
  `module.step()` runs it, with its receipt.
  """
  @spec plugin(atom(), module(), keyword()) :: {term(), MishkaCmsCore.Agent.Receipt.t() | nil}
  def plugin(step, module, opts \\ []) when step in @plugin_steps and is_atom(module) do
    Receipts.track(
      "installer:plugin:#{step}",
      Keyword.put(opts, :params, %{plugin: module}),
      fn _id -> apply(module, step, []) end
    )
  end

  @doc """
  `MishkaCmsCore.Install.Extensions.install/4`, with its receipt: the extension `key` set up on
  `site_id` with `answers`, by `actor`.
  """
  @spec install_extension(String.t(), String.t() | atom(), map(), map() | nil, keyword()) ::
          {term(), MishkaCmsCore.Agent.Receipt.t() | nil}
  def install_extension(site_id, key, answers \\ %{}, actor \\ nil, opts \\ []) do
    Receipts.track(
      "installer:extension:install",
      Keyword.merge(opts, site_id: site_id, actor: actor, params: %{key: to_string(key)}),
      fn _id -> Extensions.install(site_id, key, answers, actor) end
    )
  end

  defp library_params(%{app: app, version: version}),
    do: %{app: to_string(app), version: to_string(version)}

  defp library_params(%{app: app}), do: %{app: to_string(app), version: nil}

  @doc false
  def library_recorded(%{params: %{app: app, version: version}}) do
    case Library.get(:app, app) do
      %{version: ^version} -> {:ok, %{version: version}}
      %{version: other} -> {:mismatch, %{version: version}, %{version: other}}
      nil -> {:error, :not_found}
    end
  end

  @doc false
  def library_loaded(%{params: %{app: app, version: version}}) do
    case loaded_version(app) do
      ^version -> {:ok, %{version: version}}
      nil -> {:error, :not_loaded}
      other -> {:mismatch, %{version: version}, %{version: other}}
    end
  end

  @doc false
  def library_gone(%{params: %{app: app}}) do
    case Library.get(:app, app) do
      nil -> {:ok, %{present: false}}
      _record -> {:mismatch, %{present: false}, %{present: true}}
    end
  end

  @doc false
  def library_unloaded(%{params: %{app: app}}) do
    case loaded_version(app) do
      nil -> {:ok, %{loaded: false}}
      _version -> {:mismatch, %{loaded: false}, %{loaded: true}}
    end
  end

  defp loaded_version(app) do
    case Application.spec(String.to_existing_atom(app), :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  rescue
    ArgumentError -> nil
  end

  @doc false
  def plugin_status(%{params: %{plugin: plugin}}, :unregister) do
    case Event.get(:name, plugin) do
      nil -> {:ok, %{present: false}}
      %{status: status} -> {:mismatch, %{present: false}, %{present: true, status: status}}
    end
  end

  def plugin_status(%{params: %{plugin: plugin}}, step) do
    wanted = Map.fetch!(@plugin_statuses, step)

    case Event.get(:name, plugin) do
      %{status: status} ->
        if status in wanted,
          do: {:ok, %{status: status}},
          else: {:mismatch, %{status: List.first(wanted)}, %{status: status}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc false
  def plugin_health(%{params: %{plugin: plugin}}) do
    case Hook.plugin_health(plugin) do
      %{healthy?: true} ->
        {:ok, %{healthy?: true}}

      %{alive?: alive?, callable?: callable?} ->
        {:error, :unhealthy, %{alive?: alive?, callable?: callable?}}
    end
  end

  @doc false
  def installed_row(%{params: %{key: key}, site_id: site_id}),
    do: [key: "#{key}.installed", site_id: site_id]

  @doc false
  def installed_version(%{params: %{key: key}, site_id: site_id, result: {:ok, report}}) do
    reported = Map.get(report, :version) || "unknown"

    case Extensions.installed_version(site_id, key) do
      ^reported -> {:ok, %{version: reported}}
      nil -> {:error, :not_found}
      other -> {:mismatch, %{version: reported}, %{version: other}}
    end
  end

  def installed_version(_ctx), do: {:skip, :not_applicable}

  @doc false
  def report_complete(%{result: {:ok, report}}) do
    counts =
      Map.new([:pages, :components, :skipped_pages, :renamed_pages], &{&1, size(report[&1])})

    case counts do
      %{skipped_pages: 0, renamed_pages: 0} -> {:ok, counts}
      _some_left_out -> {:unverified, :pages_left_out, counts}
    end
  end

  def report_complete(_ctx), do: {:skip, :not_applicable}

  defp size(list) when is_list(list), do: length(list)
  defp size(count) when is_integer(count), do: count
  defp size(_none), do: 0
end
