import Config

# The extension owns its own database when it is tested on its own, so it can be developed and
# released from its own repository without the CMS around it. Nothing in here reaches a dev, prod or
# published build: `config/` is outside the hex `files:` list and this file only loads under :test.
config :mishka_cms_core, MishkaCmsCore.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  database: "mishka_cms_core_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :mishka_cms_core, ecto_repos: [MishkaCmsCore.Repo]

# The CMS's own resources reach into accounts and runtime — a post belongs to a site and is written
# by a user — so the schema this extension tests against has to include those domains, not just its
# own. Listing them here is what makes `mix ash.codegen` emit their tables into this extension's
# migrations.
config :mishka_cms_core,
  ash_domains: [
    MishkaCmsCore.Runtime,
    MishkaCmsCore.Mail
  ]

config :mishka_cms_core, MishkaCmsCore.TestEndpoint,
  http: [ip: {127, 0, 0, 1}, port: 4106],
  secret_key_base: String.duplicate("mishka-cms_core-standalone-test-secret", 2),
  pubsub_server: MishkaCmsCore.PubSub,
  server: false,
  # Without this Phoenix tries `MishkaCmsCore.ErrorView` and the real exception is replaced by
  # "no 500 html template defined", which hides whatever actually went wrong.
  render_errors: [formats: [json: MishkaCmsCore.TestErrorJSON], layout: false],
  live_view: [signing_salt: "mishka-cms-core-test-salt"]

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Jobs are asserted on, not run, so nothing drains a queue behind a test's back.
config :mishka_cms_core, Oban,
  repo: MishkaCmsCore.Repo,
  testing: :manual,
  queues: false,
  plugins: false

# Boot-time settings seeding announces itself over PubSub; tests neither need nor assert it.
config :mishka_cms_core, seed_announce: false

# Hashing is the single slowest thing in a suite that creates a user per test.
config :bcrypt_elixir, log_rounds: 1

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# Swoosh boots an HTTP client for real delivery and refuses to start without one. Tests neither send
# nor need it — the test adapter captures what would have been sent.
config :swoosh, api_client: false

config :mishka_cms_core, MishkaCmsCore.Mailer, adapter: Swoosh.Adapters.Test

# Email goes to the test adapter unless a test picks another provider — see `MishkaCmsCore.Mail`.
config :mishka_cms_core, mail_dev_mailbox: true, mail_default_provider: "dev_mailbox"

# mishka_installer decides whether to start its own supervision tree (Mnesia registry, event and
# compile handlers) from `MishkaInstaller.__information__().env`, so that ITS suite runs without
# them — but a dependency is built in the host's env, so a test run inherits that and every
# `Hook.call` returns its input untouched: no dashboard widgets, no settings:register, no filter
# seams. `:project_env` is the library's own override, and it is kept because it works whenever it
# is consulted.
#
# IT IS NOT ENOUGH ON ITS OWN. `__information__/0` reads `System.get_env("MIX_ENV")` BEFORE this
# key, and the choice is a compile-time branch in the dependency — so an exported `MIX_ENV` at the
# moment `deps/` was built silently wins, and a routine `mix deps.get` is all it takes.
# `MishkaCmsCore.Application` therefore supervises whatever the library left out, ahead of the first
# plugin and in every environment; see `MishkaCmsCore.Application.installer_children/0`.
config :mishka_installer, project_env: :dev

config :mishka_installer, MishkaInstaller.MnesiaRepo,
  mnesia_dir: Path.expand(".mnesia/test"),
  essential: [MishkaInstaller.Event.Event, MishkaInstaller.Installer.Installer]

# A message the locale has no translation for reads as its text behind a `"[<locale>] "` marker, so a
# test sees a word go through `MishkaCmsCore.Gettext` in the reader's locale without a `.po` for it.
config :mishka_cms_core, :gettext_marks_untranslated, true
