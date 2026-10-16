# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_core/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

[
  import_deps: [
    :ash_paper_trail,
    :ash_archival,
    :ash_authentication_phoenix,
    :ash_authentication,
    :ash_postgres,
    :ash_json_api,
    :ash_phoenix,
    :ash_rate_limiter,
    :ash,
    :reactor,
    :oban,
    :mishka_gervaz,
    :guarded_struct,
    :ecto,
    :ecto_sql,
    :phoenix
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs",
    "priv/*/ash_test_generator.ex",
    "priv/*/entry_dev_test_seeds.ex"
  ]
]
