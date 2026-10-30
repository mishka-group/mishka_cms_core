# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsCore.Test.Boot do
  @moduledoc """
  Starts what a suite run on its own needs around the core — the part a host's application starts in
  a deployment — so the core's suite and an extension's boot the same way.

      if Mix.Project.config()[:app] == :my_extension do
        :ok =
          MishkaCmsCore.Test.Boot.start!(
            otp_app: :my_extension,
            repo: MyExtension.Repo,
            endpoint: MyExtension.TestEndpoint,
            plugins: MishkaCmsCore.Application.plugins() ++ MyExtension.Application.plugins(),
            sweep: ["Elixir.MishkaCmsCore.Test.Plugins.", "Elixir.MyExtension.Test.Plugins."],
            js_assets: Path.expand("../priv/static/temp/js_assets/node_modules", __DIR__)
          )

        ExUnit.start()
        Ecto.Adapters.SQL.Sandbox.mode(MyExtension.Repo, :manual)
      end

  The `ExUnit.configure/1`, `ExUnit.start/0` and sandbox-mode lines stay in each `test_helper.exs`:
  they are the suite's, not the runtime's.

  The core's own application has already started `MishkaCmsCore.PubSub`, `mishka_installer`'s
  registry and the core's plugins by the time a test helper runs, as it has in a host.
  """

  alias MishkaCmsCore.Supervision
  alias MishkaCmsCore.Test.{Installer, JsAssets, ObanMigration}

  @doc """
  Boots the suite's runtime under `MishkaCmsCore.TestSupervisor`, and answers `:ok` once the plugins
  it names are live.

    * `:otp_app` (required) — the suite's application: its `Oban` config is
      `Application.fetch_env!(otp_app, Oban)`, and `AshAuthentication.Supervisor` runs for it.
    * `:repo` (required) — the repo the suite writes through, the one
      `config :mishka_cms_core, repo: …` names. Oban's tables are created in it first
      (`MishkaCmsCore.Test.ObanMigration`): they are not an Ash resource, so `mix ash.codegen` never
      emits them.
    * `:endpoint` (required) — the suite's endpoint, started last.
    * `:plugins` — the `mishka_installer` plugins the run waits on before the first test
      (`MishkaCmsCore.Test.Installer.await/2`). Default `[]`.
    * `:sweep` — module-name prefixes of the suite's own test plugins; a registration an earlier run
      left behind under one of them is removed (`MishkaCmsCore.Test.Installer.sweep!/1`). Default `[]`.
    * `:js_assets` — the `node_modules` directory the suite's esbuild `NODE_PATH` names, filled from
      `deps/` (`MishkaCmsCore.Test.JsAssets.install!/1`). Left alone when not given.
    * `:extra_children` — more children, started after the endpoint. Default `[]`.

  The children are the repo, Oban, `MishkaCmsCore.Supervision.children(:caches)` and
  `children(:engine)` — what a host starts around its repo and endpoint — then
  `AshAuthentication.Supervisor`, the endpoint and `:extra_children`. Never `children(:boot)`: a
  test builds the sites it needs.
  """
  @spec start!(keyword()) :: :ok
  def start!(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    repo = Keyword.fetch!(opts, :repo)
    endpoint = Keyword.fetch!(opts, :endpoint)

    :ok = migrate_oban!(repo)

    children =
      [
        repo,
        # The runtime workers the core owns go through Oban, so it has to exist. A suite's
        # `testing: :manual` means nothing drains a queue behind a test's back — jobs are asserted
        # on, not run.
        {Oban, Application.fetch_env!(otp_app, Oban)}
      ] ++
        Supervision.children(:caches) ++
        Supervision.children(:engine) ++
        [{AshAuthentication.Supervisor, [otp_app: otp_app]}, endpoint] ++
        Keyword.get(opts, :extra_children, [])

    {:ok, _} =
      Supervisor.start_link(children, strategy: :one_for_one, name: MishkaCmsCore.TestSupervisor)

    :ok = Installer.sweep!(Keyword.get(opts, :sweep, []))

    # esbuild resolves the generated entry file's `import … from "phoenix"` through here.
    if node_modules = Keyword.get(opts, :js_assets), do: :ok = JsAssets.install!(node_modules)

    # THE RUN STARTS ONCE THE PLUGINS ARE LIVE. Each registers from its own `handle_continue`, and on
    # a slow boot — the first run after a recompile — `mishka_installer` is not ready yet, so the
    # plugin tries again a second later, after the first tests have already asked its event: the
    # mail provider is not found and every test that sends fails, once.
    Installer.await(Keyword.get(opts, :plugins, []))
  end

  defp migrate_oban!(repo) do
    {:ok, _} = repo.start_link()
    Ecto.Migrator.up(repo, 0, ObanMigration, log: false)
    Supervisor.stop(repo)
  end
end
