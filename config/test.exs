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

# Hashing is the single slowest thing in a suite that creates a user per test.
config :bcrypt_elixir, log_rounds: 1

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
