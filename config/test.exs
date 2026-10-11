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
    MishkaCmsCore.Accounts,
    MishkaCmsCore.Notify,
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

# A fixed JWT key is fine: it signs tokens that live and die inside one test run.
config :mishka_cms_core,
  token_signing_secret: String.duplicate("mishka-cms_core-test-jwt-secret", 2)

# `ApiTenantLookupPlug` resolves the tenant from the Host header in a real request and from
# `conn.host` under this flag, because a test builds its conn rather than receiving one over a socket.
# Without it every request is answered 400 `missing_host`.
config :mishka_cms_core, env_test?: true

config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Jobs are asserted on, not run, so nothing drains a queue behind a test's back.
config :mishka_cms_core, Oban,
  repo: MishkaCmsCore.Repo,
  testing: :manual,
  queues: false,
  plugins: false

# Boot-time settings seeding announces itself over PubSub; tests neither need nor assert it.
config :mishka_cms_core, seed_announce: false

# EVERY TEST SIGNS IN FROM 127.0.0.1, so the limits the CMS ships with would throttle the suite long
# before they throttled anybody guessing a password. The tests of the limiter lift this and set
# their own through the settings.
config :mishka_cms_core, MishkaCmsCore.Accounts.AuthRateLimit, limit: 1_000_000

# A captcha provider's verify request never leaves the machine: a test answers it with
# `Req.Test.stub(MishkaCmsCore.Captcha, ...)` — see `MishkaCmsCore.Captcha.Provider.siteverify/2`.
config :mishka_cms_core, MishkaCmsCore.Captcha.Provider,
  req_options: [plug: {Req.Test, MishkaCmsCore.Captcha}]

# Hashing is the single slowest thing in a suite that creates a user per test.
config :bcrypt_elixir, log_rounds: 1

# A property is checked against 25 generated cases rather than StreamData's 100. Each case of the
# page properties builds a nested document and a changeset, and 100 of them made
# `PagePropertyTest` alone take 53 s; a property that sets its own `max_runs` keeps it.
config :stream_data, max_runs: 25

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

# The compilers read these versions even when they never invoke the binaries.
config :tailwind,
  version: "4.3.3",
  # The profile `TailwindCompiler` runs; the host names its own (the CMS calls it `mishka_cms_css`).
  # Without it every runtime CSS compile logs "unknown tailwind profile" and returns an error.
  mishka_cms_core_css: [
    args: ~w(),
    cd: Path.expand("..", __DIR__)
  ]

config :esbuild,
  version: "0.28.2",
  # The profile `JavaScriptCompiler` runs; the host names its own (the CMS calls it `mishka_cms_js`).
  mishka_cms_core_js: [
    args: [],
    env: %{"NODE_PATH" => Path.expand("../priv/static/temp/js_assets/node_modules", __DIR__)}
  ]

# A BUNDLE A DEVELOPER PLACED BY HAND WINS HERE, until a version is picked in the installer.
# Production looks up the newest release instead, so a stale file in an image cannot stand in for it —
# see `MishkaCmsCore.Runtime.Handlers.UiKitHandler.prefer_local?/0`. Both environments still fall
# back to the other source, so neither dead-ends.
config :mishka_cms_core, :prefer_local_ui_kits, true

# THE STYLED KIT FROM A FIXTURE, WITH NOTHING TO DOWNLOAD. A server downloads its kits into
# `priv/cms_ui_kits/` at install, and nothing ships there; the tests read a committed copy of
# Chelekom's styled bundle from `test/fixtures/cms_ui_kits/` instead.
config :mishka_cms_core, :ui_kits_dir, Path.expand("../test/fixtures/cms_ui_kits", __DIR__)

# The code default also offers the headless package, which is not among the fixtures, so every cold
# catalogue — the Studio sheet, the Registry tab — fell through to a real HTTP request and parsed
# Chelekom behind it, and a test waiting on that render timed out whenever the internet was slow.
# `url: nil` fails without a request, so a missing file is reported rather than fetched. A test about
# downloading configures its own list and a `:ui_kit_req_options` plug, and restores this one
# afterwards.
config :mishka_cms_core, :official_ui_kits, [
  %{key: :styled, label: "Chelekom — styled", file: "chelekom.json", tag: "test", url: nil}
]

# A message the locale has no translation for reads as its text behind a `"[<locale>] "` marker, so a
# test sees a word go through `MishkaCmsCore.Gettext` in the reader's locale without a `.po` for it.
config :mishka_cms_core, :gettext_marks_untranslated, true

# CLDR data for a language other than English (`MishkaCmsCore.Localized`) is downloaded into
# priv/localize/locales the first time a test reads it; CI downloads it before the suite.
config :localize, otp_app: :mishka_cms_core, allow_runtime_locale_download: true
