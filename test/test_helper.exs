# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# This library's tests run in two places, and the difference matters.
#
# Standalone (`cd __extensions/mishka_cms_core && mix test`) there is no application around it, so
# everything a test touches has to be started here. A host — the CMS — already runs all of it and
# lists this directory in its own `test_paths`, so when the helper is loaded from there it must do
# nothing at all: starting a second repo, endpoint or Oban on top of the host's would fight it.
if Mix.Project.config()[:app] == :mishka_cms_core do
  # The repo, Oban, the caches and the runtime compiler a host starts around its repo and endpoint
  # (`MishkaCmsCore.Supervision`), then the test endpoint; Oban's tables first, swept test plugins an
  # earlier run left registered, the `node_modules` esbuild resolves `import … from "phoenix"`
  # through, and a run that starts once the plugins are live. The PubSub and the partition counter
  # are the core application's own, already running. See `MishkaCmsCore.Test.Boot`.
  :ok =
    MishkaCmsCore.Test.Boot.start!(
      otp_app: :mishka_cms_core,
      repo: MishkaCmsCore.Repo,
      endpoint: MishkaCmsCore.TestEndpoint,
      plugins: MishkaCmsCore.Application.plugins(),
      sweep: ["Elixir.MishkaCmsCore.Test.Plugins."],
      js_assets: Application.app_dir(:mishka_cms_core, "priv/static/temp/js_assets/node_modules")
    )

  # `render_async/1` WAITS THIS LONG, and 100ms is not a number anybody here chose. LiveView's
  # default is `Application.fetch_env!(:ex_unit, :assert_receive_timeout)`, and every `render_async`
  # in these suites is waiting on a real database load — an admin modal's `start_async` record fetch,
  # most of them. On a machine running another suite beside this one that load takes longer than
  # 100ms, and the test fails with "expected async processes to finish within 100ms" from a line that
  # was asserting something else entirely.
  #
  # Raising it here rather than at 201 call sites: it is the knob LiveView itself reads, it covers
  # every future `render_async` without anyone remembering, and it costs nothing on a passing run —
  # a longer timeout only delays FAILURES, never successes.
  #
  # The bound covers the slowest of those tasks, a module compile (the preview modal's Force compile).
  # One second failed such a wait while a second suite shared the machine.
  ExUnit.configure(assert_receive_timeout: :timer.seconds(30))

  # The `:node` tests run browser JavaScript in Node.js. Without it they are left out, and the run
  # says so.
  if is_nil(System.find_executable("node")) do
    IO.puts("Node.js is not installed: the :node tests are excluded.")
    ExUnit.configure(exclude: [:node | ExUnit.configuration()[:exclude] || []])
  end

  # The `:performance` tests time the ETS states against a wall-clock limit, which a shared CI
  # machine misses now and then. They run on demand: `mix test --include performance`.
  ExUnit.configure(exclude: [:performance | ExUnit.configuration()[:exclude] || []])

  ExUnit.start()
  Ecto.Adapters.SQL.Sandbox.mode(MishkaCmsCore.Repo, :manual)
end
