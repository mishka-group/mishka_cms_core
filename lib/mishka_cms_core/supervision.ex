# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Supervision do
  @moduledoc """
  The runtime processes the host supervises for the core, in three phases named by where the host
  puts them in its own tree.

  `MishkaCmsCore.Application` starts what nothing of the host's needs to come first:
  `MishkaCmsCore.PubSub`, `mishka_installer`'s registry when the library does not start it, and
  the core's plugins. What is left needs the host's repo, its endpoint, or both, so the host lists
  it in its own children:

      children =
        [MyApp.Repo, {Oban, oban_config}] ++
          MishkaCmsCore.Supervision.children(:caches) ++
          [MyAppWeb.Endpoint] ++
          MishkaCmsCore.Supervision.children(:engine) ++
          [{AshAuthentication.Supervisor, [otp_app: :my_app]}] ++
          MishkaCmsCore.Supervision.children(:boot)

    * `:caches` — the ETS caches a request reads before anything else: sites, settings,
      translations, redirects, signed-in viewers and the sign-in rate limits. After the repo, which
      they load from, and before the endpoint, so an offline site is never served while its cache is
      still loading (a site not loaded yet is not found, which refuses rather than opens).
    * `:engine` — routing and page metadata, the compiled assets, the compile failures, and the
      runtime compiler: the gate that bounds how many compiles run at once, the registry that makes
      concurrent requests for one module wait on a single compile, the partitioned supervisor the
      compiles run under, and the task supervisor `MishkaCmsCore.Runtime.Handlers.BootHandler` and
      the sitemap jobs run their unlinked tasks under. After the endpoint.
    * `:boot` — `MishkaCmsCore.Runtime.Handlers.BootHandler`, which compiles every site when the
      node starts. Last, since it uses everything above; none in a test run
      (`config :mishka_cms_core, env_test?: true`), where each test builds what it needs.

  The test harness starts `:caches` and `:engine` the same way (`MishkaCmsCore.Test.Boot`).
  """

  alias MishkaCmsCore.Runtime.Handlers
  alias MishkaCmsCore.Runtime.States

  @type phase :: :caches | :engine | :boot

  @doc "The child specs of `phase`, in start order."
  @spec children(phase()) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children(:caches) do
    [
      States.SiteState,
      States.SettingsState,
      States.TranslationsState,
      States.RedirectsState,
      States.ViewerState,
      States.RateLimitState
    ]
  end

  def children(:engine) do
    [
      States.WebRunTimeMetaDataState,
      States.AssetsState,
      States.CompileFailureState,
      Handlers.CompileGate,
      {Registry, keys: :unique, name: MishkaCms.ModuleCompilerHandlerRegistry},
      {PartitionSupervisor,
       child_spec: DynamicSupervisor,
       name: Handlers.ModuleCompilerHandlerPartition,
       partitions: System.schedulers_online()},
      {Task.Supervisor, name: MishkaCmsCore.Runtime.TaskSupervisor}
    ]
  end

  def children(:boot) do
    if Application.get_env(:mishka_cms_core, :env_test?, false),
      do: [],
      else: [Handlers.BootHandler]
  end
end
