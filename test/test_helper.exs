# This library's tests run in two places, and the difference matters.
#
# Standalone (`cd __extensions/mishka_cms_core && mix test`) there is no application around it, so
# everything a test touches has to be started here. A host — the CMS — already runs all of it and
# lists this directory in its own `test_paths`, so when the helper is loaded from there it must do
# nothing at all: starting a second repo, endpoint or Oban on top of the host's would fight it.
if Mix.Project.config()[:app] == :mishka_cms_core do
  # Oban's tables are not an Ash resource, so `mix ash.codegen` never emits them. Create them before
  # anything that enqueues starts — see `MishkaCmsCore.Test.ObanMigration`.
  {:ok, _} = MishkaCmsCore.Repo.start_link()
  Ecto.Migrator.up(MishkaCmsCore.Repo, 0, MishkaCmsCore.Test.ObanMigration, log: false)
  :ok = Supervisor.stop(MishkaCmsCore.Repo)

  children = [
    MishkaCmsCore.Repo,
    # The runtime workers this library owns go through Oban, so it has to exist. `testing: :manual`
    # means nothing drains a queue behind a test's back — jobs are asserted on, not run.
    {Oban, Application.fetch_env!(:mishka_cms_core, Oban)},
    {Phoenix.PubSub, name: MishkaCmsCore.PubSub},
    MishkaCmsCore.Runtime.States.SiteState,
    MishkaCmsCore.TestEndpoint
  ]

  {:ok, _} =
    Supervisor.start_link(children, strategy: :one_for_one, name: MishkaCmsCore.TestSupervisor)

  # A TEST PLUGIN THAT OUTLIVED ITS RUN. MishkaInstaller keeps registrations in Mnesia, which is on
  # disk and survives the run that made them — so a suite killed part-way (a crash, a Ctrl-C, a
  # timeout) leaves its plugin registered forever, and every later run boots with it live. That is
  # invisible and it changes unrelated suites: a leftover `builder:components` plugin puts an extra
  # card in the palette, and a test asserting on one card sees two.
  #
  # Only this project's own test plugins are swept — a real plugin belongs to whoever installed it.
  for event <- List.wrap(MishkaInstaller.Event.Event.get()),
      String.starts_with?(to_string(event.name), "Elixir.MishkaCmsCore.Test.Plugins.") do
    MishkaInstaller.Event.Event.unregister(:name, event.name, false)
  end

  # `render_async/1` WAITS THIS LONG, and 100ms is not a number anybody here chose. LiveView's
  # default is `Application.fetch_env!(:ex_unit, :assert_receive_timeout)`, and every `render_async`
  # in these suites is waiting on a real database load — the editor's `start_async` record fetch,
  # most of them. On a machine running another suite beside this one that load takes longer than
  # 100ms, and the test fails with "expected async processes to finish within 100ms" from a line that
  # was asserting something else entirely.
  #
  # Raising it here rather than at 156 call sites: it is the knob LiveView itself reads, it covers
  # every future `render_async` without anyone remembering, and it costs nothing on a passing run —
  # a longer timeout only delays FAILURES, never successes.
  #
  # The bound is the editor's own for its slowest mount task: opening it on a page that places a
  # runtime component awaits `warm_components`, a module compile the editor allows 30 seconds. One
  # second failed that wait while a second suite shared the machine.
  ExUnit.configure(assert_receive_timeout: :timer.seconds(30))

  ExUnit.start()
  Ecto.Adapters.SQL.Sandbox.mode(MishkaCmsCore.Repo, :manual)
end
